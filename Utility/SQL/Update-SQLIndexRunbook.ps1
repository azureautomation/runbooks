
<#PSScriptInfo

.VERSION 1.01

.GUID d8707af6-8ba7-4c3b-97d8-37eb99531982

.AUTHOR AzureAutomationTeam

.COMPANYNAME 

.COPYRIGHT 

.TAGS AzureAutomation SQL OMS Utility

.LICENSEURI 

.PROJECTURI https://github.com/azureautomation/runbooks/blob/master/Utility/ASM/SQL/Update-SQLIndexRunbook.ps1

.ICONURI 

.EXTERNALMODULEDEPENDENCIES 

.REQUIREDSCRIPTS 

.EXTERNALSCRIPTDEPENDENCIES 

.RELEASENOTES


#>

#Requires -Module Azure

<# 

.DESCRIPTION 
     This runbook indexes all of the tables in a given database if the fragmentation is
    above a certain percentage. 
    It highlights how to break up calls into smaller chunks, 
    in this case each table in a database, and use checkpoints. 
    This allows the runbook job to resume for the next chunk of work even if the 
    fairshare feature of Azure Automation puts the job back into the queue every 3 hours.  

#> 
Param()


<#
.SYNOPSIS 
    Indexes tables in a database if they have a high fragmentation

.DESCRIPTION
    This runbook indexes all of the tables in a given database if the fragmentation is
    above a certain percentage. 
    It highlights how to break up calls into smaller chunks, 
    in this case each table in a database, and use checkpoints. 
    This allows the runbook job to resume for the next chunk of work even if the 
    fairshare feature of Azure Automation puts the job back into the queue every 3 hours. 

.PARAMETER SqlServer
    Name of the SqlServer

.PARAMETER Database
    Name of the database
    
.PARAMETER SQLCredentialName
    Name of the Automation PowerShell credential setting from the Automation asset store. 
    This setting stores the username and password for the SQL Azure server

.PARAMETER FragPercentage
    Optional parameter for specifying over what percentage fragmentation to index database
    Default is 20 percent
 
 .PARAMETER RebuildOffline
    Optional parameter to rebuild indexes offline if online fails 
    Default is false
    
 .PARAMETER Table
    Optional parameter for specifying a specific table to index
    Default is all tables
    
.PARAMETER SqlServerPort
    Optional parameter for specifying the SQL port 
    Default is 1433
    
.EXAMPLE
    Update-SQLIndexRunbook -SqlServer "server.database.windows.net" -Database "Finance" -SQLCredentialName "FinanceCredentials"

.EXAMPLE
    Update-SQLIndexRunbook -SqlServer "server.database.windows.net" -Database "Finance" -SQLCredentialName "FinanceCredentials" -FragPercentage 30

.EXAMPLE
    Update-SQLIndexRunbook -SqlServer "server.database.windows.net" -Database "Finance" -SQLCredentialName "FinanceCredentials" -Table "Customers" -RebuildOffline $True

.NOTES
    AUTHOR: System Center Automation Team
    LASTEDIT: Oct 8th, 2014 
#>
workflow Update-SQLIndexRunbook
{
    param(
        [parameter(Mandatory=$True)]
        [string] $SqlServer,
    
        [parameter(Mandatory=$True)]
        [string] $Database,
    
        [parameter(Mandatory=$True)]
        [string] $SQLCredentialName,
            
        [parameter(Mandatory=$False)]
        [int] $FragPercentage = 20,

        [parameter(Mandatory=$False)]
        [int] $SqlServerPort = 1433,
        
        [parameter(Mandatory=$False)]
        [boolean] $RebuildOffline = $False,

        [parameter(Mandatory=$False)]
        [string] $Table
                  
    )

    # Get the stored username and password from the Automation credential
    $SqlCredential = Get-AutomationPSCredential -Name $SQLCredentialName
    if ($SqlCredential -eq $null)
    {
        throw "Could not retrieve '$SQLCredentialName' credential asset. Check that you created this first in the Automation service."
    }
    
    $SqlUsername = $SqlCredential.UserName 
    $SqlPass = $SqlCredential.GetNetworkCredential().Password
    
    $TableNames = Inlinescript {
      
        # Define the connection to the SQL Database
        $Conn = New-Object System.Data.SqlClient.SqlConnection("Server=tcp:$using:SqlServer,$using:SqlServerPort;Database=$using:Database;User ID=$using:SqlUsername;Password=$using:SqlPass;Trusted_Connection=False;Encrypt=True;Connection Timeout=30;")
         
        # Open the SQL connection
        $Conn.Open()
        
        # SQL command to find tables and their average fragmentation
        $SQLCommandString = @"
        SELECT a.object_id, avg_fragmentation_in_percent
        FROM sys.dm_db_index_physical_stats (
               DB_ID(N'$Database')
             , OBJECT_ID(0)
             , NULL
             , NULL
             , NULL) AS a
        JOIN sys.indexes AS b 
        ON a.object_id = b.object_id AND a.index_id = b.index_id;
"@
        # Return the tables with their corresponding average fragmentation
        $Cmd=new-object system.Data.SqlClient.SqlCommand($SQLCommandString, $Conn)
        $Cmd.CommandTimeout=600
        
        # Execute the SQL command
        Write-Verbose ("Fetching Fragmented Table Stats...")
        $FragmentedTable=New-Object system.Data.DataSet
        $Da=New-Object system.Data.SqlClient.SqlDataAdapter($Cmd)
        [void]$Da.fill($FragmentedTable)

 
        # Get the list of tables with their object ids
        $SQLCommandString = @"
        SELECT  '[' + s.name + '].[' + t.name + ']' AS TableName, t.OBJECT_ID FROM sys.tables t inner join sys.schemas s on t.schema_id = s.schema_id
"@

        $Cmd=new-object system.Data.SqlClient.SqlCommand($SQLCommandString, $Conn)
        $Cmd.CommandTimeout=120

        # Execute the SQL command
        $TableSchema =New-Object system.Data.DataSet
        $Da=New-Object system.Data.SqlClient.SqlDataAdapter($Cmd)
        [void]$Da.fill($TableSchema)


        # Return the table names that have high fragmentation
        ForEach ($FragTable in $FragmentedTable.Tables[0])
        {
            Write-Verbose ("Table Object ID:" + $FragTable.Item("object_id"))
            Write-Verbose ("Fragmentation:" + $FragTable.Item("avg_fragmentation_in_percent"))
            
            If ($FragTable.avg_fragmentation_in_percent -ge $Using:FragPercentage)
            {
                # Table is fragmented. Return this table for indexing by finding its name
                ForEach($Id in $TableSchema.Tables[0])
                {
                    if ($Id.OBJECT_ID -eq $FragTable.object_id.ToString())
                     {
                        # Found the table name for this table object id. Return it
                        Write-Verbose ("Found a table to index! : " +  $Id.Item("TableName"))
                        $Id.TableName
                    }
                }
            }
        }

        $Conn.Close()
    }

    # If a specific table was specified, then find this table if it needs to indexed, otherwise
    # set the TableNames to $null since we shouldn't process any other tables.
    If ($Table)
    {
        Write-Verbose ("Single Table specified: $Table")
        If ($TableNames -contains $Table)
        {
            $TableNames = $Table
        }
        Else
        {
            # Remove other tables since only a specific table was specified.
            Write-Verbose ("Table not found: $Table")
            $TableNames = $Null
        }
    }

    # Interate through tables with high fragmentation and rebuild indexes
    ForEach ($TableName in $TableNames)
    {
      Write-Verbose "Creating checkpoint"
      Checkpoint-Workflow
      Write-Verbose "Indexing Table $TableName..."
      
      InlineScript {
          
        $SQLCommandString = @"
        EXEC('ALTER INDEX ALL ON $Using:TableName REBUILD with (ONLINE=ON)')
"@

        # Define the connection to the SQL Database
        $Conn = New-Object System.Data.SqlClient.SqlConnection("Server=tcp:$using:SqlServer,$using:SqlServerPort;Database=$using:Database;User ID=$using:SqlUsername;Password=$using:SqlPass;Trusted_Connection=False;Encrypt=True;Connection Timeout=30;")
        
        # Open the SQL connection
        $Conn.Open()

        # Define the SQL command to run. In this case we are getting the number of rows in the table
        $Cmd=new-object system.Data.SqlClient.SqlCommand($SQLCommandString, $Conn)
        # Set the Timeout to be less than 30 minutes since the job will get queued if > 30
        # Setting to 25 minutes to be safe.
        $Cmd.CommandTimeout=1500

        # Execute the SQL command
        Try 
        {
            $Ds=New-Object system.Data.DataSet
            $Da=New-Object system.Data.SqlClient.SqlDataAdapter($Cmd)
            [void]$Da.fill($Ds)
        }
        Catch
        {
            if (($_.Exception -match "offline") -and ($Using:RebuildOffline) )
            {
                Write-Verbose ("Building table $Using:TableName offline")
                $SQLCommandString = @"
                EXEC('ALTER INDEX ALL ON $Using:TableName REBUILD')
"@              

                # Define the SQL command to run. 
                $Cmd=new-object system.Data.SqlClient.SqlCommand($SQLCommandString, $Conn)
                # Set the Timeout to be less than 30 minutes since the job will get queued if > 30
                # Setting to 25 minutes to be safe.
                $Cmd.CommandTimeout=1500

                # Execute the SQL command
                $Ds=New-Object system.Data.DataSet
                $Da=New-Object system.Data.SqlClient.SqlDataAdapter($Cmd)
                [void]$Da.fill($Ds)
            }
            Else
            {
                # Will catch the exception here so other tables can be processed.
                Write-Error "Table $Using:TableName could not be indexed. Investigate indexing each index instead of the complete table $_"
             }
        }
        # Close the SQL connection
        $Conn.Close()
      }  
    }

    Write-Verbose "Finished Indexing"
}
