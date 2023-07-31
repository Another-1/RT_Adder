Write-Host 'Проверяем версию Powershell...'
If ( $PSVersionTable.PSVersion -lt [version]'7.1.0.0') {
    Write-Host 'У вас слишком древний Powershell, обновитесь с https://github.com/PowerShell/PowerShell#get-powershell ' -ForegroundColor Red
    Pause
    Exit
}
Write-Host 'Подгружаем функции'
. "$PSScriptRoot\_functions.ps1"

try { . "$PSScriptRoot\_client_ssd.ps1" }
catch { }

if ( -not ( [bool](Get-InstalledModule -Name PsIni -ErrorAction SilentlyContinue) ) ) {
    Write-Output 'Не установлен модуль PSIni для чтения настроек Web-TLO, ставим...'
    Install-Module -Name PsIni -Scope CurrentUser -Force
}
if ( -not ( [bool](Get-InstalledModule -Name PSSQLite -ErrorAction SilentlyContinue) ) ) {
    Write-Output 'Не установлен модуль PSSQLite для получения данных из базы Web-TLO, ставим...'
    Install-Module -Name PSSQLite -Scope CurrentUser -Force
}

If ( -not ( Test-path "$PSScriptRoot\_settings.ps1" ) ) {
    # . "$PSScriptRoot\_setuper.ps1"
    Set-Preferences
}
else { . "$PSScriptRoot\_settings.ps1" }

Write-Output 'Читаем настройки Web-TLO'

$ini_path = $tlo_path + '\data\config.ini'
$ini_data = Get-IniContent $ini_path

# if ( !$forced_sections ) {
$sections = $ini_data.sections.subsections.split( ',' )
if ( $forced_sections ) {
    Write-Host 'Анализируем forced_sections'
    $forced_sections = $forced_sections.Replace(' ', '')
    $forced_sections_hash = @()
    $forced_sections.split(',') | ForEach-Object { $forced_sections_hash += $_ }
}

if ( ( Get-Date -Format HH ) -eq '04' -and ( Get-Date -Format mm ) -in '20'..'52' ) {
    Write-Host 'Подождём окончания профилактических работ на сервере'
    while ( ( Get-Date -Format HH ) -eq '04' -and ( Get-Date -Format mm ) -in '20'..'52' ) {
        Start-Sleep -Seconds 60
    }
}

Write-Host 'Достаём из TLO данные о разделах'
$section_details = @{}
$ini_data.Keys | Where-Object { $_ -match '^\d+$' } | ForEach-Object {
    $section_details[$_.ToInt32( $nul ) ] = @($ini_data[ $_ ].client, $ini_data[ $_ ].'data-folder', $ini_data[ $_ ].'data-sub-folder', $ini_data[ $_ ].'hide-topics', $ini_data[ $_ ].'label', $ini_data[$_].'control-peers' )
}
if ( ( $nul -eq $tracker_torrents ) -or ( $env:TERM_PROGRAM -ne 'vscode' ) ) { $tracker_torrents = @{} }

$forum = @{}
Set-ForumDetails $forum

if ( $forum.ProxyURL -and $forum.ProxyPassword -and $forum.ProxyPassword -ne '') {
    $proxyPass = ConvertTo-SecureString $ini_data.proxy.password -AsPlainText -Force
    $proxyCred = New-Object System.Management.Automation.PSCredential -ArgumentList $forum.ProxyLogin, $proxyPass
}

# подтягиваем чёрный список если нужно.
if ( $nul -ne $get_blacklist -and $get_blacklist.ToUpper() -eq 'N' ) { $blacklist = Get-Blacklist }
if ( $tracker_torrents.count -eq 0 ) {
    foreach ( $section in $sections ) {
        $section_torrents = Get-SectionTorrents $forum $section $max_seeds
        $section_torrents.Keys | Where-Object { $section_torrents[$_][0] -in (0, 2, 3, 8, 10, 11 ) } | ForEach-Object {
            $tracker_torrents[$section_torrents[$_][7]] = @{
                id             = $_
                section        = $section.ToInt32($nul)
                status         = $section_torrents[$_][0]
                name           = $nul
                reg_time       = $section_torrents[$_][2]
                size           = $section_torrents[$_][3]
                seeders        = $section_torrents[$_][1]
                hidden_section = $section_details[$section.toInt32($nul)][3]
                releaser       = $section_torrents[$_][8]
            }
        }
    }
}
$clients = @{}
if ( $nul -eq $clients_tor_sort -or ( $env:TERM_PROGRAM -ne 'vscode' ) ) {
    $clients_torrents = @()
    $clients_tor_sort = @{}
    $clients_tor_srt2 = @{}
}

if ( $clients_torrents.count -eq 0 ) {
    Write-Host 'Получаем из TLO данные о клиентах'
    $ini_data.keys | Where-Object { $_ -match '^torrent-client' -and $ini_data[$_].client -eq 'qbittorrent' } | ForEach-Object {
        $clients[$ini_data[$_].id] = @{ Login = $ini_data[$_].login; Password = $ini_data[$_].password; Name = $ini_data[$_].comment; IP = $ini_data[$_].hostname; Port = $ini_data[$_].port; }
    } 

    foreach ($clientkey in $clients.Keys ) {
        $client = $clients[ $clientkey ]
        Initialize-Client( $client )
        $client_torrents = Get-Torrents $client '' $false $nul $clientkey
        Get-TopicIDs $client $client_torrents
        $clients_torrents += $client_torrents
    }

    Write-Host 'Сортируем таблицы'
    $clients_torrents | Where-Object { $nul -ne $_.topic_id } | ForEach-Object {
        $clients_tor_sort[$_.hash] = $_.topic_id
        $clients_tor_srt2[$_.topic_id] = @{
            client_key = $_.client_key
            save_path  = $_.save_path
            category   = $_.category
            name       = $_.name
            hash       = $_.hash
        }
    }
}
Write-Host 'Ищем новые раздачи'
if (!$min_days ) { $min_days = 0 }

    $new_torrents_keys = $tracker_torrents.keys | Where-Object { $nul -eq $clients_tor_sort[$_] } | Where-Object { $get_hidden -eq 'Y' -or $tracker_torrents[$_].hidden_section -eq '0' } 

Write-Host ( 'Новых раздач: ' + $new_torrents_keys.count )

if ( $nul -ne $get_blacklist -and $get_blacklist.ToUpper() -eq 'N' ) {
    Write-Host 'Отсеиваем раздачи из чёрного списка'
    $new_torrents_keys = $new_torrents_keys | Where-Object { $nul -eq $blacklist[$_] }
    Write-Host ( 'Осталось раздач: ' + $new_torrents_keys.count )
}

if ( $forced_sections_hash ) {
    Write-Host 'Применяем forced_sections'
    $new_torrents_keys = $new_torrents_keys | Where-Object { $tracker_torrents[$_].section.ToString() -in $forced_sections_hash }
    Write-Host ( 'Осталось раздач: ' + $new_torrents_keys.count )
}

Remove-Variable -Name added -ErrorAction SilentlyContinue
Remove-Variable -Name refreshed -ErrorAction SilentlyContinue
$refreshed_ids = @()
$added = @{}
$refreshed = @{}
if ( $new_torrents_keys ) {
    $ProgressPreference = 'SilentlyContinue'
    foreach ( $new_torrent_key in $new_torrents_keys ) {
        $new_tracker_data = $tracker_torrents[$new_torrent_key]
        $subfolder_kind = $section_details[$new_tracker_data.section][2].ToInt16($null)
        # $existing_torrent = $clients_torrents | Where-Object { $_.topic_id -eq $new_tracker_data.id }
        $existing_torrent = $clients_tor_srt2[ $new_tracker_data.id ]
        if ( $existing_torrent ) {
            $client = $clients[$existing_torrent.client_key]
        }
        else {
            $client = $clients[$section_details[$new_tracker_data.section][0]]
            if (!$client) {
                $client = $clients[$section_details[$new_tracker_data.section][0].ToString()]
            }
        }
        if ( $existing_torrent ) {
            if ( !$forum.sid ) { Initialize-Forum $forum }
            $new_torrent_file = Get-ForumTorrentFile $new_tracker_data.id
            $text = "Обновляем раздачу " + $new_tracker_data.id + ' в клиенте ' + $client.Name + '(' + $new_tracker_data.size + ')'
            Write-Host $text
            if ( $nul -ne $tg_token -and '' -ne $tg_token ) {
                if ( !$refreshed[ $client.Name] ) { $refreshed[ $client.Name] = @() }
                $refreshed[ $client.Name] += ( 'https://rutracker.org/forum/viewtopic.php?t=' + $new_tracker_data.id )
                $refreshed_ids += $new_tracker_data.id
            }
            # подмена временного каталога если раздача хранится на SSD.
            if ( $nul -ne $ssd -and $existing_torrent.save_path[0] -in $ssd[$existing_torrent.client_key] ) {
                $url_get = $client.ip + ':' + $client.Port + '/api/v2/app/preferences'
                $old_temp_path = ( ( Invoke-WebRequest -Uri $url_get -WebSession $client.sid ).content | ConvertFrom-Json ).temp_path
                if ( $old_temp_path[0] -ne $existing_torrent.save_path[0] ) {
                    Write-Host ( 'Временно меняем temp path на ' + $existing_torrent.save_path[0] + ':\Incomplete' )
                    $url_set = $client.ip + ':' + $client.Port + '/api/v2/app/setPreferences'
                    $param = @{ json = ( @{"temp_path" = ( $existing_torrent.save_path[0] + ':\Incomplete') } | ConvertTo-Json -Compress ) }
                    Invoke-WebRequest -Uri $url_set -WebSession $client.sid -Body $param -Method POST
                    Start-Sleep -Seconds 1
                }
                else { Remove-Variable -Name old_temp_path -ErrorAction SilentlyContinue }
            }
            Add-ClientTorrent $client $new_torrent_file $existing_torrent.save_path $existing_torrent.category

            While ($true) {
                Write-Host 'Ждём 5 секунд чтобы раздача точно "подхватилась"'
                Start-Sleep -Seconds 5
                $new_tracker_data.name = ( Get-Torrents $client '' $false $new_torrent_key $nul ).name
                if ( $nul -ne $new_tracker_data.name ) { break }
            }
            if ( $new_tracker_data.name -eq $existing_torrent.name -and $subfolder_kind -le '2') {
                Remove-ClientTorrent $client $existing_torrent.hash $false
            }
            else {
                Remove-ClientTorrent $client $existing_torrent.hash $true
            }
            if ( $old_temp_path ) {
                Write-Host ( 'Возвращаем temp path на ' + $old_temp_path )
                $param = @{ json = ( @{"temp_path" = $old_temp_path } | ConvertTo-Json -Compress ) }
                Invoke-WebRequest -Uri $url_set -WebSession $client.sid -Body $param -Method POST
                Remove-Variable -Name old_temp_path
            }
            Start-Sleep -Milliseconds 100
        }
        elseif ( !$existing_torrent -and $get_news -eq 'Y' -and ( $new_tracker_data.reg_time -lt ( ( Get-Date -UFormat %s  ).ToInt32($nul) - $min_days * 86400 ) ) -or $new_tracker_data.releaser -in $priority_releasers ) {
            if ( !$forum.sid ) { Initialize-Forum $forum }
            $new_torrent_file = Get-ForumTorrentFile $new_tracker_data.id
            $text = "Добавляем раздачу " + $new_tracker_data.id + ' в клиент ' + $client.Name
            Write-Host $text
            if ( $nul -ne $tg_token -and '' -ne $tg_token ) {
                if ( !$added[ $client.Name] ) { $added[ $client.Name] = @() }
                $added[ $client.Name] += ( 'https://rutracker.org/forum/viewtopic.php?t=' + $new_tracker_data.id )
            }
            $save_path = $section_details[$new_tracker_data.section][1]
            if ( $subfolder_kind -eq 1 ) {
                $save_path = ( $save_path -replace ( '\\$', '')) + '/' + $new_tracker_data.id # добавляем ID к имени папки для сохранения
            }
            elseif ( $subfolder_kind -eq 2 ) {
                $save_path = ( $save_path -replace ( '\\$', '')) + '/' + $new_torrent_key  # добавляем hash к имени папки для сохранения
            }
            Add-ClientTorrent $client $new_torrent_file $save_path $section_details[$new_tracker_data.section][4]
        }
        elseif ( !$existing_torrent -eq 'Y' -and $get_news -eq 'Y' -and ( $new_tracker_data.reg_time -ge ( ( Get-Date -UFormat %s  ).ToInt32($nul) - $min_days * 86400 ) -and $new_tracker_data.releaser -notin $priority_releasers ) ) {
            Write-Host 'Раздача' $new_tracker_data.id 'слишком новая.'
        }
        else { Pause }
    }
} # по наличию новых раздач.

Remove-Variable -Name obsolete -ErrorAction SilentlyContinue
if ( $nul -ne $tg_token -and '' -ne $tg_token -and $report_obsolete -and $report_obsolete -eq 'Y' ) {
    $obsolete_keys = $clients_tor_sort.Keys | Where-Object { !$tracker_torrents[$_] } | Where-Object { $refreshed_ids -notcontains $clients_tor_sort[$_] } | `
        Where-Object { $tracker_torrents.Values.id -notcontains $clients_tor_sort[$_] } | Where-Object { !$ignored_obsolete -or $nul -eq $ignored_obsolete[$clients_tor_sort[$_]] }
    $obsolete_torrents = $clients_torrents | Where-Object { $_.hash -in $obsolete_keys }
    $obsolete_torrents | ForEach-Object {
        If ( !$obsolete ) { $obsolete = @{} }
        Write-Host ( "Левая раздача " + $_.topic_id + ' в клиенте ' + $clients[$_.client_key].Name )
        if ( !$obsolete[$clients[$_.client_key].Name] ) { $obsolete[ $clients[$_.client_key].Name] = @() }
        $obsolete[$clients[$_.client_key].Name] += ( 'https://rutracker.org/forum/viewtopic.php?t=' + $_.topic_id )
    }
}

# Очистим ненужные данные из памяти.
Remove-Variable -Name clients_tor_sort -ErrorAction SilentlyContinue
Remove-Variable -Name clients_tor_srt2 -ErrorAction SilentlyContinue

if ( $refreshed.Count -gt 0 -or $added.Count -gt 0 -or $obsolete.Count -gt 0 -and $tg_token -ne '' -and $tg_chat -ne '' ) {
    Send-TGReport $refreshed $added $obsolete $tg_token $tg_chat
}
If ( $send_reports -eq 'Y' -and $php_path -and ( $refreshed.Count -gt 0 -or $added.Count -gt 0 ) ) {
    Send-Report $true # с паузой.
}

Remove-Variable -Name added -ErrorAction SilentlyContinue
Remove-Variable -Name refreshed -ErrorAction SilentlyContinue

if ( $control -eq 'Y' ) {
    . "$PSScriptRoot\controller.ps1"
}