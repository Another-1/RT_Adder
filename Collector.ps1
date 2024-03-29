Write-Output 'Проверяем версию Powershell...'
If ( $PSVersionTable.PSVersion -lt [version]'7.1.0.0') {
    Write-Host 'У вас слишком древний Powershell, обновитесь с https://github.com/PowerShell/PowerShell#get-powershell ' -ForegroundColor Red
    Pause
    Exit
}
Write-Output 'Подгружаем функции'
. "$PSScriptRoot\_functions.ps1"

$separator = Get-Separator
$csv_path = $PSScriptRoot + $separator + 'data.csv'

if ( -not ( [bool](Get-InstalledModule -Name PsIni -ErrorAction SilentlyContinue) ) ) {
    Write-Output 'Не установлен модуль PSIni для чтения настроек Web-TLO, ставим...'
    Install-Module -Name PsIni -Scope CurrentUser -Force
}

If ( -not ( Test-path "$PSScriptRoot\_settings.ps1" ) ) {
    Set-Preferences
}
else { . "$PSScriptRoot\_settings.ps1" }

Write-Output 'Читаем настройки Web-TLO'

$ini_path = $tlo_path + '\data\config.ini'
$ini_data = Get-IniContent $ini_path

$clients = @{}

$clients = Get-Clients
$result = [System.Collections.ArrayList]::new()

foreach ($clientkey in $clients.Keys ) {
    $client = $clients[$clientkey]
    Write-Output ( 'Обрабатываем клиент ' + $clients[$clientkey].Name + ' по адресу ' + $client_address + ':' + $client.Port)
    Initialize-Client $client $false
    $client_address = ( $client.ip -match '^\d*\.\d*\.\d*\.\d*$') ? $client.ip : ( 'http://' + $client.ip )
    # Write-Output ( 'Подключаемся к клиенту ' + $clients[$clientkey].Name + ' по адресу ' + $client_address + ':' + $client.Port )
    $client_data = ( ( Invoke-WebRequest -Uri ( $client_address + ':' + $client.Port + '/api/v2/sync/maindata') -WebSession $client.sid ).Content | ConvertFrom-Json -AsHashtable )
    $row = [PSCustomObject]@{ address = ( 'http://' + $client.IP + ':' + $client.Port ) }
    $cl_version = ( Invoke-WebRequest -Uri ( $client_address + ':' + $client.Port + '/api/v2/app/version') -WebSession $client.sid ).Content 
    $row | Add-Member -Name 'version' -MemberType NoteProperty -Value $cl_version
    $client_total = $client_data.torrents.Count
    $row | Add-Member -Name 'total' -MemberType NoteProperty -Value $client_total
    $client_down = ( $client_data.torrents.GetEnumerator() | Where-Object { $_.Value.state -in ('downloading', 'stalledDL', 'pausedDL', 'queuedDL','forcedDL', 'allocating') } ).count
    $row | Add-Member -Name 'downloading' -MemberType NoteProperty -Value $client_down
    $client_paused = ( $client_data.torrents.GetEnumerator() | Where-Object { $_.Value.state -eq 'pausedUP' } ).count
    $row | Add-Member -Name 'paused' -MemberType NoteProperty -Value $client_paused
    $client_checking = ( $client_data.torrents.GetEnumerator() | Where-Object { $_.Value.state -eq 'checkingUP' } ).count
    $row | Add-Member -Name 'checking' -MemberType NoteProperty -Value $client_checking
    $client_errored = ( $client_data.torrents.GetEnumerator() | Where-Object { $_.Value.state -in ( 'error', 'missingFiles', 'unknown' ) } ).count
    $row | Add-Member -Name 'errored' -MemberType NoteProperty -Value $client_errored
    $client_trackerless = ( $client_data.torrents.GetEnumerator() | Where-Object { $_.Value.tracker -eq '' -and $_.Value.state -notin ( 'pausedUP', 'checkingUP', 'checkingDL' ) } ).Count
    $row | Add-Member -Name 'trackerless' -MemberType NoteProperty -Value $client_trackerless
    $row | Add-Member -Name 'ratio' -MemberType NoteProperty -Value $client_data.server_state.global_ratio
    $row | Add-Member -Name 'dht' -MemberType NoteProperty -Value $client_data.server_state.dht_nodes
    $row | Add-Member -Name 'free_space' -MemberType NoteProperty -Value ( [math]::Round( $client_data.server_state.free_space_on_disk / 1024 / 1024 / 1024 ) )
    $row | Add-Member -Name 'peers' -MemberType NoteProperty -Value $client_data.server_state.total_peer_connections
    $row | Add-Member -Name 'cache_hits' -MemberType NoteProperty -Value $client_data.server_state.read_cache_hits
    $row | Add-Member -Name 'buffer_size' -MemberType NoteProperty -Value ( [math]::Round( $client_data.server_state.total_buffers_size  / 1024 / 1024 / 1024 ) )
    $row | Add-Member -Name 'time_in_queue' -MemberType NoteProperty -Value $client_data.server_state.average_time_queue
    $result.Add( $row ) | Out-Null
}
$result | Export-Csv -Path $csv_path -Force -Delimiter ','
