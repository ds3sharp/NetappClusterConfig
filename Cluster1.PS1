Author...............Jeff Sharp  
Creation Date........2/15/2021

Description
=============================================================
This script configures CFS / NFS / IscSI on a Netapp filer.





Modification Log
Date    | Initials | +/- | Description
============================================================
02/15/2021 | Initial Draft



Automate Cluster Setup
https://netapp.io/2017/03/17/automate-cluster-setup-12-steps-with-ontap-powershell-toolkit-4-1/
#>

#SETUP Global Variables
# define the cluster to connect to
$filer = "172.23.1.44"

#$Credential = Get-Credential
$password = ConvertTo-SecureString -AsPlainText -Force P@ssw0rd # Update this to whatever the password of the netapp cluster is. 
$credential = new-object management.automation.pscredential admin, $password
#Use $credential as the credential object to pass to the -Credential parameter in any cmdlet that supports this parameter.

#Show the currently connected controller(s)
#$global:CurrentNcController

#Disconnect from all controllers
#$global:CurrentNcController = $null

# 1. Import the netapp cmdlets - DataOntap Module can be downloaded from Netapp Support or Powershell Gallery
Import-Module DataOntap

# Connect to the Netapp Cluster
Connect-NcController -name $filer -Credential $Credential -HTTPS | Out-Null #suppress the output to the screen with out-null

#Apply licenses

# Licenses for node 1
Add-NcLicense -License YVUCRRRRYVHXCFABGAAAAAAAAAAA,WKQGSRRRYVHXCFABGAAAAAAAAAAA,SOHOURRRYVHXCFABGAAAAAAAAAAA,`
YBSOYRRRYVHXCFABGAAAAAAAAAAA,KQSRRRRRYVHXCFABGAAAAAAAAAAA,MBXNQRRRYVHXCFABGAAAAAAAAAAA,QDDSVRRRYVHXCFABGAAAAAAAAAAA,`
CYAHWRRRYVHXCFABGAAAAAAAAAAA,GUJZTRRRYVHXCFABGAAAAAAAAAAA,OSYVWRRRYVHXCFABGAAAAAAAAAAA,UZLKTRRRYVHXCFABGAAAAAAAAAAA,EJFDVRRRYVHXCFABGAAAAAAAAAAA

# License for Node 2
# Add-NcLicense -License MHEYKUNFXMSMUCEZFAAAAAAAAAAA,KWZBMUNFXMSMUCEZFAAAAAAAAAAA,GARJOUNFXMSMUCEZFAAAAAAAAAAA,`
# MNBKSUNFXMSMUCEZFAAAAAAAAAAA,YBCNLUNFXMSMUCEZFAAAAAAAAAAA,ANGJKUNFXMSMUCEZFAAAAAAAAAAA,EPMNPUNFXMSMUCEZFAAAAAAAAAAA,`
# QJKCQUNFXMSMUCEZFAAAAAAAAAAA,UFTUNUNFXMSMUCEZFAAAAAAAAAAA,CEIRQUNFXMSMUCEZFAAAAAAAAAAA,ILVFNUNFXMSMUCEZFAAAAAAAAAAA,SUOYOUNFXMSMUCEZFAAAAAAAAAAA

# Configure time settings to UTC and NTP server
# FlackboxB domain...
New-NcNtpServer -ServerName 172.23.5.1 -IsPreferred
# Make sure that you don't specify a node when setting the cluster time
Set-NcTime -Timezone UTC
Set-NcTime -DateTime (get-date)
#Set-NcTime -Timezone America/Denver
Get-NcTime

#--------------------------- CIFS Server -----------------------------------
# Create Aggregate
New-NcAggr -Name aggr_cifs -DiskCount 10 -RaidType raid_dp

# Create CIFS SVM
New-NcVserver -Name C1CIFS -RootVolume c1cifs_root -RootVolumeAggregate aggr_cifs 
Remove-NcVserverProtocol -Name C1CIFS -Protocol nfs,fcp,iscsi #Since there is not paramater to specify allowed protocols, you have to go back and remove unwanted protocols
Add-NcVserverProtocol -Name C1CIFS -Protocol cifs

# Create Data Lifs
New-NcNetInterface -Name C1CIFS_LIF1 -Vserver C1CIFS -Role data -Node C4N1-01 -Port e0d -DataProtocols cifs -Address 172.23.2.45 -Netmask 255.255.255.0 -FirewallPolicy data -AdministrativeStatus up
New-NcNetRoute -Destination 0.0.0.0/0 -Gateway 172.23.2.254 -VserverContext C1CIFS
New-NcNetDns -Domains flackboxb.lab -NameServers 172.23.5.1 -VserverContext C1CIFS #configure DNS for cifs server

# Create volumes and shares
# SVM / vol#. Ex C1CIFS-VOL01
New-NcVol -VserverContext C1CIFS -Name cifs_vol01 -aggregate aggr_cifs -size 500m -JunctionPath /cifs_vol01

# Create CIFS server / join to domain
Add-NcCifsServer -VserverContext C1CIFS -Name C1CIFS -Domain flackboxb.lab -AdminUsername Administrator -AdminPassword P@ssw0rd
Set-NcNetDdns -Enable $true -UseSecure $true -DomainName flackboxb.lab -VserverContext C1CIFS 

# Create CIFS share
Add-NcCifsShare -VserverContext C1CIFS -Name cifs_vol01 -Path /cifs_vol01

# Set Share permissions
Add-NcCifsShareAcl -VserverContext C1CIFS -Share cifs_vol01 -UserOrGroup Group1 -Permission full_control 


#--------------------------- NFS Server -----------------------------------
# Create Aggregate
New-NcAggr -Name aggr_nfs -DiskCount 10 -RaidType raid_dp

# Create NFS SVM
New-NcVserver -Name C1NFS -RootVolume c1nfs_root -RootVolumeAggregate aggr_nfs
Remove-NcVserverProtocol -Name C1NFS -Protocol cifs,fcp,iscsi #Since there is not paramater to specify allowed protocols, you have to go back and remove unwanted protocols

# Turn on the cifs server, with default NFS V3 protocol. Add arguments for other versions
Enable-NcNfs -VserverContext C1NFS

# These settings are required if you are using the native windows client
#https://kb.netapp.com/Advice_and_Troubleshooting/Data_Storage_Software/ONTAP_OS/Mount_failure_with_%22Network_Error_-_53%22_on_Native_Windows_NFS_clients
#https://kb.netapp.com/Advice_and_Troubleshooting/Data_Storage_Software/ONTAP_OS/Top_Windows_NFSv3.0_Issues%2C_Workarounds_and_Best_Practices

$config = Get-NcNfsService -Template
$config.IsMountRootonlyEnabled = $false #when enabled, this setting only allow connections from ports <1024
$config.IsV3MsDosClientEnabled = $true  #enable this setting so that windows clients can connect
$config.EnableEjukebox = $false
$config.IsNfsv3ConnectionDropEnabled = $false
Set-NcNfsService $config -VserverContext C1NFS


# Create Data Lifs
New-NcNetInterface -Name C1NFS_LIF1 -Vserver C1NFS -Role data -Node C4N1-01 -Port e0d -DataProtocols nfs -Address 172.23.2.46 -Netmask 255.255.255.0 -FirewallPolicy data -AdministrativeStatus up
New-NcNetRoute -Destination 0.0.0.0/0 -Gateway 172.23.2.254 -VserverContext C1NFS

# Create NFS Exports
New-NcVol -VserverContext C1NFS -Name nfs_vol01 -aggregate aggr_nfs -size 500m -JunctionPath /nfs_vol01 -UnixPermissions 777
Add-NcNfsExport /nfs_vol01 -ReadWrite all-hosts -NoSuid -SecurityFlavors sys -VserverContext C1NFS
# Add an access rule to the default export policy. You must create one or more rules for the default export policy before clients can access data on the SVM.
New-NcExportRule -Policy default -Index 1 -ClientMatch 0.0.0.0/0 -Protocol nfs -ReadOnlySecurityFlavor any -ReadWriteSecurityFlavor any -VserverContext C1NFS

#--------------------------- ISCSI Server -----------------------------------
# Create Aggregate
New-NcAggr -Name aggr_san -DiskCount 10 -RaidType raid_dp

# Create Iscsi server
New-NcVserver -Name C1SAN -RootVolume c1san_root -RootVolumeAggregate aggr_san 
Remove-NcVserverProtocol -Name C1SAN -Protocol cifs,nfs,fcp #Since there is not paramater to specify allowed protocols, you have to go back and remove unwanted protocols

# Create Data lif
New-NcNetInterface -Name C1SAN_LIF1 -Vserver C1SAN -Role data -Node C4N1-01 -Port e0d -DataProtocols iscsi -Address 172.23.2.47 -Netmask 255.255.255.0 -FirewallPolicy data -AdministrativeStatus up
New-NcNetRoute -Destination 0.0.0.0/0 -Gateway 172.23.2.254 -VserverContext C1SAN

# Add Volume for ISCSI LUNS
New-NcVol -VserverContext C1SAN -Name san_vol01 -aggregate aggr_san -size 2g -JunctionPath /san_vol01 

# Add the ISCSI Service
Add-NcIscsiService -Name ic001 -VserverContext C1SAN


# Add an ISCSI Initiator Target Portal
Add-NcHostIscsiTargetPortal -VserverContext C1SAN

# Create an ISCSI LUN
New-NcLun -Path /vol/san_vol01/L1 -size 100m -VserverContext C1SAN -Unreserved 
