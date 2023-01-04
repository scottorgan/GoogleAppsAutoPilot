<#
.SYNOPSIS
  Script to download and install the latest version both Google Chrome & Drive

.DESCRIPTION
    Script to install both Google Chrome & Drive during Autopilot by downloading the latest setup files from evergreen urls

    The original version of this script was written by Jan Ketil Skanke @ MSEndpointMgr to download and install the latest release of the Microsoft 365 (Office) Apps.
    It works so well that I decided to modify it (barely) to install the latest versions of Google Chrome and Drive.
    
    A big thank you to Mr. Skanke and MSEndPointMgr for their awesome work.

    Original Script Links:
    Post:   https://msendpointmgr.com/2022/10/23/installing-m365-apps-as-win32-app-in-intune/
    GitHub: https://github.com/MSEndpointMgr/M365Apps/blob/main/LICENSE

.EXAMPLE
    powershell.exe -executionpolicy bypass -file InstallGoogleApps.ps1

.NOTES
    Version:        1.0
    Original Author:Jan Ketil Skanke
    Modified By:    Scott Organ
    Creation Date:  01.07.2021
    Modified Date:  01.04.2023
#>
#region parameters
[CmdletBinding()]
Param (
    [Parameter(Mandatory = $false)]
    [string]$XMLUrl
)
#endregion parameters
#Region Functions
function Write-LogEntry {
    param (
        [parameter(Mandatory = $true, HelpMessage = "Value added to the log file.")]
        [ValidateNotNullOrEmpty()]
        [string]$Value,
        [parameter(Mandatory = $true, HelpMessage = "Severity for the log entry. 1 for Informational, 2 for Warning and 3 for Error.")]
        [ValidateNotNullOrEmpty()]
        [ValidateSet("1", "2", "3")]
        [string]$Severity,
        [parameter(Mandatory = $false, HelpMessage = "Name of the log file that the entry will written to.")]
        [ValidateNotNullOrEmpty()]
        [string]$FileName = $LogFileName
    )
    # Determine log file location
    $LogFilePath = Join-Path -Path $env:SystemRoot -ChildPath $("Temp\$FileName")
	
    # Construct time stamp for log entry
    $Time = -join @((Get-Date -Format "HH:mm:ss.fff"), " ", (Get-WmiObject -Class Win32_TimeZone | Select-Object -ExpandProperty Bias))
	
    # Construct date for log entry
    $Date = (Get-Date -Format "MM-dd-yyyy")
	
    # Construct context for log entry
    $Context = $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
	
    # Construct final log entry
    $LogText = "<![LOG[$($Value)]LOG]!><time=""$($Time)"" date=""$($Date)"" component=""$($LogFileName)"" context=""$($Context)"" type=""$($Severity)"" thread=""$($PID)"" file="""">"
	
    # Add value to log file
    try {
        Out-File -InputObject $LogText -Append -NoClobber -Encoding Default -FilePath $LogFilePath -ErrorAction Stop
        if ($Severity -eq 1) {
            Write-Verbose -Message $Value
        }
        elseif ($Severity -eq 3) {
            Write-Warning -Message $Value
        }
    }
    catch [System.Exception] {
        Write-Warning -Message "Unable to append log entry to $LogFileName.log file. Error message at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
    }
}
function Start-DownloadFile {
    param(
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$URL,

        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )
    Begin {
        # Construct WebClient object
        $WebClient = New-Object -TypeName System.Net.WebClient
    }
    Process {
        # Create path if it doesn't exist
        if (-not(Test-Path -Path $Path)) {
            New-Item -Path $Path -ItemType Directory -Force | Out-Null
        }

        # Start download of file
        $WebClient.DownloadFile($URL, (Join-Path -Path $Path -ChildPath $Name))
    }
    End {
        # Dispose of the WebClient object
        $WebClient.Dispose()
    }
}
function Invoke-FileCertVerification {
    param(
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath
    )
    # Get a X590Certificate2 certificate object for a file
    $Cert = (Get-AuthenticodeSignature -FilePath $FilePath).SignerCertificate
    $CertStatus = (Get-AuthenticodeSignature -FilePath $FilePath).Status
    if ($Cert){
        #Verify signed by Google and Validity
        if ($cert.Subject -match "O=Google LLC" -and $CertStatus -eq "Valid"){
            #Verify Chain and check if Root is DigiCert
            $chain = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Chain
            $chain.Build($cert) | Out-Null
            $RootCert = $chain.ChainElements | ForEach-Object {$_.Certificate}| Where-Object {$PSItem.Subject -match "CN=DigiCert Trusted Root G4"}
            if (-not [string ]::IsNullOrEmpty($RootCert)){
                #Verify root certificate exists in local Root Store
                $TrustedRoot = Get-ChildItem -Path "Cert:\LocalMachine\Root" -Recurse | Where-Object { $PSItem.Thumbprint -eq $RootCert.Thumbprint}
                if (-not [string]::IsNullOrEmpty($TrustedRoot)){
                    Write-LogEntry -Value "Verified setupfile signed by : $($Cert.Issuer)" -Severity 1
                    Return $True
                }
                else {
                    Write-LogEntry -Value  "No trust found to root cert - aborting" -Severity 2
                    Return $False
                }
            }
            else {
                Write-LogEntry -Value "Certificate chain not verified to Google - aborting" -Severity 2 
                Return $False
            }
        }
        else {
            Write-LogEntry -Value "Certificate not valid or not signed by Google - aborting" -Severity 2 
            Return $False
        }  
    }
    else {
        Write-LogEntry -Value "Setup file not signed - aborting" -Severity 2
        Return $False
    }
}
#Endregion Functions

#Region Initialisations
$LogFileName = "GoogleAppsSetup.log"
#Endregion Initialisations

#Initate Install
Write-LogEntry -Value "Initiating Google Apps setup process" -Severity 1
#Attempt Cleanup of SetupFolder
if (Test-Path "$($env:SystemRoot)\Temp\GoogleSetup") {
    Remove-Item -Path "$($env:SystemRoot)\Temp\GoogleSetup" -Recurse -Force -ErrorAction SilentlyContinue
}

$SetupFolder = (New-Item -ItemType "directory" -Path "$($env:SystemRoot)\Temp" -Name GoogleSetup -Force).FullName

### INSTALL GOOGLE CHROME ###
try {
    #Download latest installer file
    $SetupEverGreenURL = "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi"
    Write-LogEntry -Value "Attempting to download latest Chrome setup MSI file" -Severity 1
    Start-DownloadFile -URL $SetupEverGreenURL -Path $SetupFolder -Name "googlechromestandaloneenterprise64.msi"
    
    try {
        #Start install preparations
        $SetupFilePath = Join-Path -Path $SetupFolder -ChildPath "googlechromestandaloneenterprise64.msi"
        if (-Not (Test-Path $SetupFilePath)) {
            Throw "Error: Setup file not found"
        }
        Write-LogEntry -Value "Setup file ready at $($SetupFilePath)" -Severity 1
        try {
            #Prepare Chrome Installation
            if (Invoke-FileCertVerification -FilePath $SetupFilePath){
                #Starting Chrome setup               
                Try {
                    #Running Chrome installer
                    Write-LogEntry -Value "Starting Google Chrome MSI Install" -Severity 1
                    $ChromeInstall = Start-Process "msiexec" -ArgumentList "/i $SetupFilePath /qn" -Wait -PassThru -ErrorAction Stop
                }
                catch [System.Exception] {
                    Write-LogEntry -Value  "Error running the Google Chrome install. Errormessage: $($_.Exception.Message)" -Severity 3
                }
            }
            else {
                Throw "Error: Unable to verify setup file signature"
            }
        }
        catch [System.Exception] {
            Write-LogEntry -Value  "Error preparing Chrome installation. Errormessage: $($_.Exception.Message)" -Severity 3
        }
        
    }
    catch [System.Exception] {
        Write-LogEntry -Value  "Error finding Chrome setup file. Errormessage: $($_.Exception.Message)" -Severity 3
    }
    
}
catch [System.Exception] {
    Write-LogEntry -Value  "Error downloading Chrome setup file. Errormessage: $($_.Exception.Message)" -Severity 3
}

#### INSTALL GOOGLE DRIVE ###
try {
    #Download latest setup file
    $SetupEverGreenURL = "https://dl.google.com/drive-file-stream/GoogleDriveSetup.exe"
    Write-LogEntry -Value "Attempting to download latest Drive setup file" -Severity 1
    Start-DownloadFile -URL $SetupEverGreenURL -Path $SetupFolder -Name "GoogleDriveSetup.exe"
    
    try {
        #Start install preparations
        $SetupFilePath = Join-Path -Path $SetupFolder -ChildPath "GoogleDriveSetup.exe"
        if (-Not (Test-Path $SetupFilePath)) {
            Throw "Error: Drive setup file not found"
        }
        Write-LogEntry -Value "Drive setup file ready at $($SetupFilePath)" -Severity 1
        try {
            #Prepare Drive Installation
            $DriveVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo("$($SetupFolder)\GoogleDriveSetup.exe").FileVersion 
            Write-LogEntry -Value "Drive Setup is running version $DriveVersion" -Severity 1
            if (Invoke-FileCertVerification -FilePath $SetupFilePath){
                #Starting Drive setup               
                Try {
                    #Running Drive installer
                    Write-LogEntry -Value "Starting Drive setup" -Severity 1
                    $DriveInstall = Start-Process $SetupFilePath -ArgumentList "--silent --gsuite_shortcuts=false --skip_launch_new" -Wait -PassThru -ErrorAction Stop
                }
                catch [System.Exception] {
                    Write-LogEntry -Value  "Error running the Drive installer. Errormessage: $($_.Exception.Message)" -Severity 3
                }
            }
            else {
                Throw "Error: Unable to verify Drive setup file signature"
            }
        }
        catch [System.Exception] {
            Write-LogEntry -Value  "Error preparing Drive installation. Errormessage: $($_.Exception.Message)" -Severity 3
        }
        
    }
    catch [System.Exception] {
        Write-LogEntry -Value  "Error finding Drive setup file. Errormessage: $($_.Exception.Message)" -Severity 3
    }
    
}
catch [System.Exception] {
    Write-LogEntry -Value  "Error downloading Drive setup file. Errormessage: $($_.Exception.Message)" -Severity 3
}

#Cleanup 
if (Test-Path "$($env:SystemRoot)\Temp\GoogleSetup"){
    Remove-Item -Path "$($env:SystemRoot)\Temp\GoogleSetup" -Recurse -Force -ErrorAction SilentlyContinue
}
Write-LogEntry -Value "Google Apps setup completed" -Severity 1