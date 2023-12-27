Clear-Host
write-host "Starting script at $(Get-Date)"
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module -Name Az.Synapse -Force

$selectedSub = Read-Host "Enter the subscription id"
az account set --subscription $selectedSub


# Prompt user for a password for the SQL Database
$sqlUser = "SQLUser"
write-host ""
$sqlPassword = ""
$complexPassword = 0

while ($complexPassword -ne 1)
{
    $SqlPassword = Read-Host "Enter a password to use for the $sqlUser login.
    `The password must meet complexity requirements:
    ` - Minimum 8 characters. 
    ` - At least one upper case English letter [A-Z]
    ` - At least one lower case English letter [a-z]
    ` - At least one digit [0-9]
    ` - At least one special character (!,@,#,%,^,&,$)
    ` "

    if(($SqlPassword -cmatch '[a-z]') -and ($SqlPassword -cmatch '[A-Z]') -and ($SqlPassword -match '\d') -and ($SqlPassword.length -ge 8) -and ($SqlPassword -match '!|@|#|%|\^|&|\$'))
    {
        $complexPassword = 1
	    Write-Output "Password $SqlPassword accepted. Make sure you remember this!"
    }
    else
    {
        Write-Output "$SqlPassword does not meet the complexity requirements."
    }
}

# Register resource providers
Write-Host "Registering resource providers...";
$provider_list = "Microsoft.Synapse", "Microsoft.Sql", "Microsoft.Storage", "Microsoft.Compute"
foreach ($provider in $provider_list){
    $result = Register-AzResourceProvider -ProviderNamespace $provider
    $status = $result.RegistrationState
    Write-Host "$provider : $status"
}

$resourceGroupName = "rg-jasonr"

# Choose a random region
#Write-Host "Finding an available region. This may take several minutes...";
#$delay = 0, 30, 60, 90, 120 | Get-Random
#Start-Sleep -Seconds $delay # random delay to stagger requests from multi-student classes
#$preferred_list = "australiaeast","centralus","southcentralus","eastus2","northeurope","southeastasia","uksouth","westeurope","westus","westus2"
#$locations = Get-AzLocation | Where-Object {
#    $_.Providers -contains "Microsoft.Synapse" -and
#    $_.Providers -contains "Microsoft.Sql" -and
#    $_.Providers -contains "Microsoft.Storage" -and
#    $_.Providers -contains "Microsoft.Compute" -and
#    $_.Location -in $preferred_list
#}
# $max_index = $locations.Count - 1
#$rand = (0..$max_index) | Get-Random
$Region = "northcentralus" #$locations.Get($rand).Location

# Test for subscription Azure SQL capacity constraints in randomly selected regions
# (for some subsription types, quotas are adjusted dynamically based on capacity)
 $success = 0

#Write-Host "Creating $resourceGroupName resource group in $Region ..."
#New-AzResourceGroup -Name $resourceGroupName -Location $Region | Out-Null

# Create Synapse workspace
$synapseWorkspace = "synapsejasonr"
$dataLakeAccountName = "datalakejasonr"
$sparkPool = "sparkjasonr"
$sqlDatabaseName = "sqljasonr"


write-host "Creating $synapseWorkspace Synapse Analytics workspace in $resourceGroupName resource group..."
write-host "(This may take some time!)"
New-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName `
  -TemplateFile "setup.json" `
  -Mode Complete `
  -workspaceName $synapseWorkspace `
  -dataLakeAccountName $dataLakeAccountName `
  -sparkPoolName $sparkPool `
  -sqlDatabaseName $sqlDatabaseName `
  -sqlUser $sqlUser `
  -sqlPassword $sqlPassword `
  -uniqueSuffix $resourceGroupName `
  -Force

# Pause Data Explorer pool
#write-host "Pausing the $adxpool Data Explorer Pool..."
#Stop-AzSynapseKustoPool -Name $adxpool -ResourceGroupName $resourceGroupName -WorkspaceName $synapseWorkspace -NoWait

# Make the current user and the Synapse service principal owners of the data lake blob store
write-host "Granting permissions on the $dataLakeAccountName storage account..."
write-host "(you can ignore any warnings!)"
$subscriptionId = (Get-AzContext).Subscription.Id
$userName = ((az ad signed-in-user show) | ConvertFrom-JSON).UserPrincipalName
$id = (Get-AzADServicePrincipal -DisplayName $synapseWorkspace).id
try
{
		New-AzRoleAssignment -Objectid $id -RoleDefinitionName "Storage Blob Data Owner" -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$dataLakeAccountName" -ErrorAction SilentlyContinue;
}
catch 
{
	write-output $_.Exception.Message -Foregroundcolor Red
}
try
{
	New-AzRoleAssignment -SignInName $userName -RoleDefinitionName "Storage Blob Data Owner" -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$dataLakeAccountName" -ErrorAction SilentlyContinue;
}
catch 
{
	write-output $_.Exception.Message -Foregroundcolor Red
}

# Create database
write-host "Creating the $sqlDatabaseName database..."
sqlcmd -S "$synapseWorkspace.sql.azuresynapse.net" -U $sqlUser -P $sqlPassword -d $sqlDatabaseName -I -i setup.sql

# Load data
write-host "Loading data..."
Get-ChildItem "./data/*.txt" -File | Foreach-Object {
    write-host ""
    $file = $_.FullName
    Write-Host "$file"
    $table = $_.Name.Replace(".txt","")
    bcp dbo.$table in $file -S "$synapseWorkspace.sql.azuresynapse.net" -U $sqlUser -P $sqlPassword -d $sqlDatabaseName -f $file.Replace("txt", "fmt") -q -k -E -b 5000
}

# Pause SQL Pool
#write-host "Pausing the $sqlDatabaseName SQL Pool..."
#Suspend-AzSynapseSqlPool -WorkspaceName $synapseWorkspace -Name $sqlDatabaseName -AsJob

# Upload files
write-host "Loading data..."
$storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $dataLakeAccountName
$storageContext = $storageAccount.Context
Get-ChildItem "./files/*.csv" -File | Foreach-Object {
    write-host ""
    $file = $_.Name
    Write-Host $file
    $blobPath = "sales_data/$file"
    Set-AzStorageBlobContent -File $_.FullName -Container "files" -Blob $blobPath -Context $storageContext
}

# Create KQL script
# Removing until fix for Bad Request error is resolved
# New-AzSynapseKqlScript -WorkspaceName $synapseWorkspace -DefinitionFile "./files/ingest-data.kql"

write-host "Script completed at $(Get-Date)"
