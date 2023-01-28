. "$PSScriptRoot\RT_settings.ps1"
. "$PSScriptRoot\RT_functions.ps1"

$database_path = $PSScriptRoot + '\topics.sqlite'
$conn = New-SqliteConnection -DataSource $database_path

$INI_data = Get-IniContent "\\nas-2\OpenServer\domains\webtlo.local\data\config.ini"

$sections = $INI_data.sections.subsections.split( ',' )

### DEBUG ### 
# $sections = $sections | Where-Object { $_ -ne '1842' }
# $Sections = @(704)
### DEBUG ### 

$section_details = @{}
$INI_data.Keys | Where-Object { $_ -match '^\d+$' } | ForEach-Object { $section_details[$_.ToInt32( $nul ) ] = @($INI_data[ $_ ].client, $INI_data[ $_ ].'data-folder' ) }
$tracker_torrents = @{}

foreach ( $section in $sections ) {
    Write-Host ('Получаем с трекера раздачи раздела ' + $section )
    $i = 1
    # while ( $i -lt 10) {
    while ( $true) {
        Remove-Variable -Name tmp_torrents -ErrorAction SilentlyContinue
        try {
            $tmp_torrents = ( ( Invoke-WebRequest -Uri "https://api.rutracker.cc/v1/static/pvc/f/$section" ).Content | ConvertFrom-Json -AsHashtable ).result
            break
        }
        catch { Start-Sleep -Seconds 10; $i++; Write-Host "Попытка номер $i" -ForegroundColor Cyan }
    }
    if ( !$tmp_torrents ) {
        Write-Host 'Не получилось' -ForegroundColor Red
        exit 
    }
    $tmp_torrents.Keys | Where-Object { $tmp_torrents[$_][0] -in (0, 2, 3, 8, 10 ) } | ForEach-Object {
        # $tracker_torrents[$_] = @{ hash = $tmp_torrents[$_][7]; section = $section }
        $tracker_torrents[$tmp_torrents[$_][7]] = @{ id = $_; section = $section.ToInt32($nul); status = $tmp_torrents[$_][0]; name = $nul; reg_time = $tmp_torrents[$_][2]; size = $tmp_torrents[$_][3] }
    }
}

$clients_torrents = @()
$clients_tor_sort = @{}

### DEBUG ### 
# $clients.Remove('1')
# $clients.Remove('3')
### DEBUG ### 

foreach ($clientkey in $clients.Keys ) {
    $client = $clients[ $clientkey ]
    Initialize-Client( $client )
    $client_torrents = Get-Torrents $client '' $false $nul $clientkey
    Get-TopicIDs $client $client_torrents
    $clients_torrents += $client_torrents
    # $client_torrents_list.Keys | ForEach-Object { $clients_torrents[$_] = $torrents_list[$_] }
}
$conn.Close()

$clients_torrents | Where-Object { $nul -ne $_.topic_id } | ForEach-Object {
    $clients_tor_sort[$_.hash] = $_.topic_id
}
$new_torrents_keys = $tracker_torrents.keys | Where-Object { $nul -eq $clients_tor_sort[$_] }

$update_required = $false
if ( $new_torrents_keys) {
    # для телеги
    $token = "1440830495:AAGbJ-XIR_r19iSJRTG1ZdTxM0Q04Dvnfgw"
    $chat_id = '17822987' # лично я
    $payload = @{
        "chat_id"                  = $chat_id;
        "text"                     = $nul;
        "parse_mode"               = 'html';
        "disable_web_page_preview" = $true
    }
    # для телеги

    $ProgressPreference = 'SilentlyContinue'
    # if ( !$forum.sid ) {
    #     Initialize-Forum
    # }
    # $now = Get-Date -UFormat %s
    foreach ( $new_torrent_key in $new_torrents_keys ) {
        $new_tracker_data = $tracker_torrents[$new_torrent_key]
        $existing_torrent = $clients_torrents | Where-Object { $_.topic_id -eq $new_tracker_data.id }
        if ( $existing_torrent ) {
            $client = $clients[$existing_torrent.client_key]
        }
        else {
            $client = $clients[$section_details[$new_tracker_data.section][0]]
        }
        # if ( $new_tracker_data.size -le 50 * 1024 * 1024 * 1024 -and $existing_torrent ) {
        if ( $existing_torrent ) {
            if ( !$forum.sid ) { Initialize-Forum }
            $new_torrent_file = Get-ForumTorrentFile $new_tracker_data.id
            $payload.text = "Обновляем раздачу " + $new_tracker_data.id + ' в клиенте ' + $client.Name
            Write-Host $payload.text
            Invoke-WebRequest -Uri ("https://api.telegram.org/bot{0}/sendMessage" -f $token) -Method Post  -ContentType "application/json;charset=utf-8" -Body (ConvertTo-Json -Compress -InputObject $payload) | Out-Null
            # Remove-Variable -Name old_temp_path
            if ( $existing_torrent.save_path[0] -in $client.ssd ) {
                $url_get = $client.ip + ':' + $client.Port + '/api/v2/app/preferences'
                $old_temp_path = ( ( Invoke-WebRequest -Uri $url_get -WebSession $client.sid ).content | ConvertFrom-Json ).temp_path
                if ( $old_temp_path[0] -ne $existing_torrent.save_path[0] ) {
                    $url_set = $client.ip + ':' + $client.Port + '/api/v2/app/setPreferences'
                    $param = @{ json = ( @{"temp_path" = ( $existing_torrent.save_path[0] + ':\Incomplete') } | ConvertTo-Json -Compress ) }
                    Invoke-WebRequest -Uri $url_set -WebSession $client.sid -Body $param -Method POST
                    Start-Sleep -Seconds 1
                }
                else { Remove-Variable -Name old_temp_path -ErrorAction SilentlyContinue }
            }
            Add-ClientTorrent $client $new_torrent_file $existing_torrent.save_path $existing_torrent.category
            While ($true) {
                Start-Sleep -Seconds 5
                $new_tracker_data.name = ( Get-Torrents $client '' $false $new_torrent_key $nul ).name
                if ( $nul -ne $new_tracker_data.name ) { break }
            }
            if ( $new_tracker_data.name -eq $existing_torrent.name ) {
                Remove-ClientTorrent $client $existing_torrent.hash $false
            }
            else {
                Remove-ClientTorrent $client $existing_torrent.hash $true
            }
            if ( $old_temp_path ) {
                $param = @{ json = ( @{"temp_path" = $old_temp_path } | ConvertTo-Json -Compress ) }
                Invoke-WebRequest -Uri $url_set -WebSession $client.sid -Body $param -Method POST
            }
            $update_required = $true
            Start-Sleep -Milliseconds 100
        }
        elseif ( `
            !$existing_torrent
            # -and (( $new_tracker_data.status.ToString() -ne "0" ) -or ( $now - $new_tracker_data.reg_time -gt 7 * 24 * 60 * 60 ) )
        ) {
            if ( !$forum.sid ) { Initialize-Forum }
            $new_torrent_file = Get-ForumTorrentFile $new_tracker_data.id
            Write-Host ( "Добавляем раздачу " + $new_tracker_data.id + ' в клиент ' + $client.Name )
            $payload.text = "Добавляем раздачу " + $new_tracker_data.id + ' в клиент ' + $client.Name
            Invoke-WebRequest -Uri ("https://api.telegram.org/bot{0}/sendMessage" -f $token) -Method Post  -ContentType "application/json;charset=utf-8" -Body (ConvertTo-Json -Compress -InputObject $payload) | Out-Null
            Add-ClientTorrent $client $new_torrent_file $section_details[$new_tracker_data.section][1] ( Get-ForumName $new_tracker_data.section.ToString() )
            $update_required = $true
            Start-Sleep -Milliseconds 100
        }
        else {
            # Write-Host ( 'Большая раздача для обновления ' + $new_tracker_data.id + ',  пропускаем' ) 
            # $payload.text = 'Большая раздача для обновления ' + $new_tracker_data.id + ',  пропускаем'
            # Invoke-WebRequest -Uri ("https://api.telegram.org/bot{0}/sendMessage" -f $token) -Method Post  -ContentType "application/json;charset=utf-8" -Body (ConvertTo-Json -Compress -InputObject $payload) | Out-Null
        }
    }
    if ( $update_required ) {
        Write-Host 'Ждём 5 минут'
        Start-Sleep -Seconds 300
        Send-Report
    }
}
