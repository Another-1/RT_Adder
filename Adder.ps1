Write-Host 'Проверяем версию Powershell...'
If ( $PSVersionTable.PSVersion -lt [version]'7.1.0.0') {
    Write-Host 'У вас слишком древний Powershell, обновитесь с https://github.com/PowerShell/PowerShell#get-powershell ' -ForegroundColor Red
    Pause
    Exit
}

. "$PSScriptRoot\_functions.ps1"

if ( -not ( [bool](Get-InstalledModule -Name PsIni -ErrorAction SilentlyContinue) ) ) {
    Write-Output 'Не установлен модуль PSIni для чтения настроек Web-TLO, ставим...'
    Install-Module -Name PsIni -Scope CurrentUser -Force
}

$forum = @{}
If ( -not ( Test-path "$PSScriptRoot\_settings.ps1" ) ) {
    . "$PSScriptRoot\_setuper.ps1"    
}
else { . "$PSScriptRoot\_settings.ps1" }

Write-Output 'Читаем настройки Web-TLO'
$forceNoProxy = $false

$ini_path = $tlo_path  + '\data\config.ini'
$ini_data = Get-IniContent $ini_path

if ( -not ( [bool](Get-InstalledModule -Name PSSQLite -ErrorAction SilentlyContinue) ) ) {
    Write-Output 'Не установлен модуль PSSQLite, ставим...'
    Install-Module -Name PSSQLite -Scope CurrentUser -Force
}

$sections = $ini_data.sections.subsections.split( ',' )

Write-Host 'Достаём из TLO данные о разделах'
$section_details = @{}
$ini_data.Keys | Where-Object { $_ -match '^\d+$' } | ForEach-Object { $section_details[$_.ToInt32( $nul ) ] = @($ini_data[ $_ ].client, $ini_data[ $_ ].'data-folder' ) }
$tracker_torrents = @{}

If ( ( [bool]$ini_data.proxy.activate_forum -or [bool]$ini_data.proxy.activate_api ) -and ( -not $forceNoProxy ) ) {
    Write-Host ( 'Используем ' + $ini_data.proxy.type.Replace('socks5h','socks5') + ' прокси ' + $ini_data.proxy.hostname + ':' + $ini_data.proxy.port )
    $forum.UseApiProxy = $ini_data.proxy.activate_api
    $forum.ProxyIP = $ini_data.proxy.hostname
    $forum.ProxyPort = $ini_data.proxy.port
    $forum.ProxyURL = 'socks5://' + $ini_data.proxy.hostname + ':' + $ini_data.proxy.port
}
$forum.UseProxy = $ini_data.proxy.activate_forum
$forum.Login = $ini_data.'torrent-tracker'.login
$forum.Password = $ini_data.'torrent-tracker'.password

foreach ( $section in $sections ) {
    Write-Host ('Получаем с трекера раздачи раздела ' + $section )
    $section_torrents = Get-SectionTorrents $forum $section $max_seeds
    $section_torrents.Keys | Where-Object { $section_torrents[$_][0] -in (0, 2, 3, 8, 10 ) } | ForEach-Object {
        $tracker_torrents[$section_torrents[$_][7]] = @{ id = $_; section = $section.ToInt32($nul); status = $section_torrents[$_][0]; name = $nul; reg_time = $section_torrents[$_][2]; size = $section_torrents[$_][3]; seeders = $section_torrents[$_][1] }
    }
}

$clients = @{}
$clients_torrents = @()
$clients_tor_sort = @{}

Write-Host 'Получаем из TLO данные о клиентах'
$ini_data.keys | Where-Object { $_ -match '^torrent-client'} | ForEach-Object { $clients[$ini_data[$_].id] = @{ Login = $ini_data[$_].login; Password = $ini_data[$_].password; Name = $ini_data[$_].comment; IP = $ini_data[$_].hostname; Port = $ini_data[$_].port;}} 

foreach ($clientkey in $clients.Keys ) {
    $client = $clients[ $clientkey ]
    Initialize-Client( $client )
    $client_torrents = Get-Torrents $client '' $false $nul $clientkey
    Get-TopicIDs $client $client_torrents
    $clients_torrents += $client_torrents
}

$clients_torrents | Where-Object { $nul -ne $_.topic_id } | ForEach-Object {
    $clients_tor_sort[$_.hash] = $_.topic_id
}
$new_torrents_keys = $tracker_torrents.keys | Where-Object { $nul -eq $clients_tor_sort[$_] }

$update_required = $false
if ( $new_torrents_keys) {
    $ProgressPreference = 'SilentlyContinue'
    foreach ( $new_torrent_key in $new_torrents_keys ) {
        $new_tracker_data = $tracker_torrents[$new_torrent_key]
        $existing_torrent = $clients_torrents | Where-Object { $_.topic_id -eq $new_tracker_data.id }
        if ( $existing_torrent ) {
            $client = $clients[$existing_torrent.client_key]
        }
        else {
            $client = $clients[$section_details[$new_tracker_data.section][0]]
        }
        if ( $existing_torrent ) {
            if ( !$forum.sid ) { Initialize-Forum $forum }
            $new_torrent_file = Get-ForumTorrentFile $new_tracker_data.id
            $payload.text = "Обновляем раздачу " + $new_tracker_data.id + ' в клиенте ' + $client.Name
            Write-Host $payload.text

            Add-ClientTorrent $client $new_torrent_file $existing_torrent.save_path $existing_torrent.category

            While ($true) {
                Write-Host 'Ждём 5 секунд чтобы раздача точно "подхватилась"'
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
            $update_required = $true
            Start-Sleep -Milliseconds 100
        }
        elseif ( !$existing_torrent ) {
            if ( !$forum.sid ) { Initialize-Forum $forum }
            $new_torrent_file = Get-ForumTorrentFile $new_tracker_data.id
            Write-Host ( "Добавляем раздачу " + $new_tracker_data.id + ' в клиент ' + $client.Name )
            Add-ClientTorrent $client $new_torrent_file $section_details[$new_tracker_data.section][1] ( Get-ForumName $new_tracker_data.section.ToString() )
            $update_required = $true
            Start-Sleep -Milliseconds 100
        }
    }
    if ( $update_required ) {
        Write-Host 'Ждём 5 минут, вдруг что-то успеет скачаться...'
        Start-Sleep -Seconds 300
        Send-Report
    }
}
