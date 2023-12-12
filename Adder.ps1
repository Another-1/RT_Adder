Write-Output 'Проверяем версию Powershell...'
If ( $PSVersionTable.PSVersion -lt [version]'7.1.0.0') {
    Write-Host 'У вас слишком древний Powershell, обновитесь с https://github.com/PowerShell/PowerShell#get-powershell ' -ForegroundColor Red
    Pause
    Exit
}
Write-Output 'Подгружаем функции'
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
    Set-Preferences # $tlo_path $max_seeds $get_hidden $get_blacklist $get_news $tg_token $tg_chat
}
else { . "$PSScriptRoot\_settings.ps1" }

If ( Test-path "$PSScriptRoot\_masks.ps1" ) {
    Write-Output 'Подтягиваем названия раздач из маскированных разделов'
    . "$PSScriptRoot\_masks.ps1"
    $masks_db = @{}
    $masks_db_plain = @{}
    $masks_like = @{}
    $conn = Open-TLODatabase
    $masks.GetEnumerator() | ForEach-Object {
       
        $masks_db[$_.key] = `
        ( Invoke-SqliteQuery -Query ( 'SELECT id FROM Topics WHERE ss=' + $_.Key + ' AND na NOT LIKE "%' + ( ($masks[$_.Key] -replace ('\s', '%')) -join '%" AND na NOT LIKE "%' ) + '%"' ) -SQLiteConnection $conn ).GetEnumerator() `
        | ForEach-Object { @{$_.id.ToString() = 1 } }
        Write-Output ( 'По разделу ' + $_.key + ' найдено ' + $masks_db[$_.key].count + ' неподходящих раздач' )

        $masks_like[$_.key] = $masks[$_.key] -replace ('^|$|\s', '*')
    }
    $masks_db.Keys | ForEach-Object {
        $masks_db[$_].Keys | ForEach-Object {
            $masks_db_plain[$_] = 1
        }
    }

    # Remove-Variable -Name $masks_db -ErrorAction SilentlyContinue
    $conn.Close()
}
else {
    Remove-Variable -name masks_like -ErrorAction SilentlyContinue
    Remove-Variable -name masks_db -ErrorAction SilentlyContinue
}

Write-Output 'Читаем настройки Web-TLO'

$ini_path = $tlo_path + '\data\config.ini'
$ini_data = Get-IniContent $ini_path

$sections = $ini_data.sections.subsections.split( ',' )
if ( $forced_sections ) {
    Write-Output 'Анализируем forced_sections'
    $forced_sections = $forced_sections.Replace(' ', '')
    $forced_sections_array = @()
    $forced_sections.split(',') | ForEach-Object { $forced_sections_array += $_ }
}

Write-Output 'Ищем московское время'
$MoscowTZ = [System.TimeZoneInfo]::FindSystemTimeZoneById("Russian Standard Time")
$MoscowTime = [System.TimeZoneInfo]::ConvertTimeFromUtc((Get-Date).ToUniversalTime(), $MoscowTZ)
Write-Output ( 'Московское время ' + ( Get-Date($MoscowTime) -uformat %H ) + ' ч ' + ( Get-Date($MoscowTime) -uformat %M ) + ' мин' )

Write-Output 'Проверяем, что в Москве не 4 часа ночи (профилактика)'
if ( ( Get-Date($MoscowTime) -uformat %H ) -eq '04' ) {
    Write-Host 'Профилактические работы на сервере' -ForegroundColor Red
    exit
}

Write-Output 'Достаём из TLO данные о разделах'
$section_details = @{}
$sections | ForEach-Object {
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

# получаем с трекера список раздач каждого раздела
if ( $tracker_torrents.count -eq 0 ) {
    foreach ( $section in $sections ) {
        $section_torrents = Get-SectionTorrents $forum $section $max_seeds
        $section_torrents.Keys | Where-Object { $section_torrents[$_][0] -in (0, 2, 3, 8, 10 ) } | ForEach-Object {
            $tracker_torrents[$section_torrents[$_][7]] = @{
                id             = $_
                section        = $section.ToInt32($nul)
                status         = $section_torrents[$_][0]
                name           = $null
                reg_time       = $section_torrents[$_][2]
                size           = $section_torrents[$_][3]
                seeders        = $section_torrents[$_][1]
                hidden_section = $section_details[$section.toInt32($nul)][3]
                releaser       = $section_torrents[$_][8]
            }
        }
    }
}
# $clients = @{}
if ( $nul -eq $clients_tor_sort -or ( $env:TERM_PROGRAM -ne 'vscode' ) ) {
    $clients = @{}
    $clients_torrents = @()
    $clients_tor_sort = @{}
    $clients_tor_srt2 = @{}
}

if ( $clients_torrents.count -eq 0 ) {
    Write-Output 'Получаем из TLO данные о клиентах'
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

    Write-Output 'Сортируем таблицы'
    $clients_torrents | Where-Object { $nul -ne $_.topic_id } | ForEach-Object {
        if ( !$_.infohash_v1 -or $nul -eq $_.infohash_v1 -or $_.infohash_v1 -eq '' ) {
            # на всякий случай, сценарий непонятен.
            $_.infohash_v1 = $_.hash
        }
        $clients_tor_sort[$_.infohash_v1] = $_.topic_id

        $clients_tor_srt2[$_.topic_id] = @{
            client_key = $_.client_key
            save_path  = $_.save_path
            category   = $_.category
            name       = $_.name
            hash       = $_.hash
        }
    }
}
Write-Output 'Ищем новые раздачи'
if (!$min_days ) { $min_days = 0 }

$new_torrents_keys = $tracker_torrents.keys | Where-Object { $nul -eq $clients_tor_sort[$_] } | Where-Object { $get_hidden -eq 'Y' -or $tracker_torrents[$_].hidden_section -eq '0' } 

Write-Output ( 'Новых раздач: ' + $new_torrents_keys.count )

if ( $nul -ne $get_blacklist -and $get_blacklist.ToUpper() -eq 'N' ) {
    Write-Output 'Отсеиваем раздачи из чёрного списка'
    $new_torrents_keys = $new_torrents_keys | Where-Object { $nul -eq $blacklist[$_] }
    Write-Output ( 'Осталось раздач: ' + $new_torrents_keys.count )
}

if ( $forced_sections_array ) {
    Write-Output 'Применяем forced_sections'
    $new_torrents_keys = $new_torrents_keys | Where-Object { $tracker_torrents[$_].section.ToString() -in $forced_sections_array }
    Write-Output ( 'Осталось раздач: ' + $new_torrents_keys.count )
}

if ( $masks_db ) {
    Write-Output 'Отфильтровываем раздачи по маскам'
    $new_torrents_keys = $new_torrents_keys | Where-Object { !$masks_db_plain[$tracker_torrents[$_].id] }
    Write-Output ( 'Осталось раздач: ' + $new_torrents_keys.count )
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
        $existing_torrent = $clients_tor_srt2[ $new_tracker_data.id ]
        if ( $existing_torrent ) {
            $client = $clients[$existing_torrent.client_key]
            Write-Output ( "Раздача " + $new_tracker_data.id + ' обнаружена клиенте ' + $client.Name )
        }
        else {
            $client = $clients[$section_details[$new_tracker_data.section][0]]
            if (!$client) {
                $client = $clients[$section_details[$new_tracker_data.section][0].ToString()]
            }
        }
        
        if ( $new_tracker_data.releaser -in $priority_releasers.keys ) {
            $min_secs = $priority_releasers.keys[$new_tracker_data.releaser] * 86400
        }
        else {
            $min_secs = $min_days * 86400
        }
        if ( $existing_torrent ) {
            if ( !$forum.sid ) { Initialize-Forum $forum }
            $new_torrent_file = Get-ForumTorrentFile $new_tracker_data.id
            $on_ssd = ( $nul -ne $ssd -and $existing_torrent.save_path[0] -in $ssd[$existing_torrent.client_key] )
            $text = "Обновляем раздачу " + $new_tracker_data.id + ' в клиенте ' + $client.Name
            Write-Output $text
            if ( $nul -ne $tg_token -and '' -ne $tg_token ) {
                if ( !$refreshed[ $client.Name ] ) { $refreshed[ $client.Name] = @{} }
                if ( !$refreshed[ $client.Name ][ $new_tracker_data.section] ) { $refreshed[ $client.Name ][ $new_tracker_data.section ] = @() }
                if ( $ssd ) {
                    $refreshed[ $client.Name][ $new_tracker_data.section ] += ( 'https://' + $forum.url + '/forum/viewtopic.php?t=' + $new_tracker_data.id + ( $on_ssd ? ' SSD ' : ' HDD ' ) + $existing_torrent.save_path[0] )
                }
                else {
                    $refreshed[ $client.Name][ $new_tracker_data.section ] += ( 'https://' + $forum.url + '/forum/viewtopic.php?t=' + $new_tracker_data.id )
                }
                $refreshed_ids += $new_tracker_data.id
            }
            # подмена временного каталога если раздача хранится на SSD.
            if ( $ssd ) {
                if ( $on_ssd -eq $true ) {
                    # if ( !$client.temp_enabled ) {
                    #     $client.temp_enabled = Get-ClientSetting $client 'temp_path_enabled'
                    #     $clients[$section_details[$new_tracker_data.section][0]].temp_enabled = $client.temp_enabled
                    # }
                    # if ( $client.temp_enabled -eq $true ) { 
                    #     $old_temp_path = Get-ClientSetting $client 'temp_path'
                    #     if ( $old_temp_path[0] -ne $existing_torrent.save_path[0] ) {
                    # Write-Output ( 'Временно меняем temp path на ' + $existing_torrent.save_path[0] + ':\Incomplete' )
                    # Set-ClientSetting $client 'temp_path' ( $existing_torrent.save_path[0] + ':\Incomplete' )
                    Write-Output 'Отключаем преаллокацию'
                    Set-ClientSetting $client 'preallocate_all' $false
                    Start-Sleep -Seconds 1
                    Start-Sleep -Milliseconds 100
                    # }
                    # else { Remove-Variable -Name old_temp_path -ErrorAction SilentlyContinue }
                    # }
                }
                else {
                    Set-ClientSetting $client 'preallocate_all' $true
                    Start-Sleep -Milliseconds 100
                }
                Set-ClientSetting $client 'temp_path_enabled' $false
            }
            Add-ClientTorrent $client $new_torrent_file $existing_torrent.save_path $existing_torrent.category
            # if ( $on_ssd -eq $true ) {
            #     Set-ClientSetting $client 'preallocate_all' $true
            # }
            While ($true) {
                Write-Output 'Ждём 5 секунд чтобы раздача точно "подхватилась"'
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
            # if ( $old_temp_path ) {
            #     Write-Output ( 'Возвращаем temp path на ' + $old_temp_path )
            #     $param = @{ json = ( @{"temp_path" = $old_temp_path } | ConvertTo-Json -Compress ) }
            #     Invoke-WebRequest -Uri $url_set -WebSession $client.sid -Body $param -Method POST
            #     Remove-Variable -Name old_temp_path
            # }
            Start-Sleep -Milliseconds 100
        }
        elseif ( !$existing_torrent -and $get_news -eq 'Y' -and ( ( $new_tracker_data.reg_time -lt ( ( Get-Date -UFormat %s  ).ToInt32($nul) - $min_secs ) ) -or $new_tracker_data.status -eq 2 ) ) {
            $is_ok = $true
            if ( $masks_db -and $masks_db[$new_tracker_data.section.ToString()] -and $masks_db[$new_tracker_data.section.ToString()][$new_tracker_data.id] ) { $is_ok = $false }
            else {
                if ( $masks_like -and $masks_like[$new_tracker_data.section.ToString()] ) {
                    $new_tracker_data.name = Get-TorrentName $new_tracker_data.id
                    $is_ok = $false
                    $masks_like[$new_tracker_data.section.ToString()] | ForEach-Object {
                        if ( -not $is_ok -and $new_tracker_data.name -like $_ ) {
                            $is_ok = $true
                        }
                    }
                }
            }
            if ( -not $is_ok ) {
                Write-Output ( 'Раздача ' + $new_tracker_data.name + ' отброшена фильтрами' )
                continue
            }
            if ( !$forum.sid ) { Initialize-Forum $forum }
            $new_torrent_file = Get-ForumTorrentFile $new_tracker_data.id
            $text = "Добавляем раздачу " + $new_tracker_data.id + ' в клиент ' + $client.Name
            Write-Output $text
            if ( $nul -ne $tg_token -and '' -ne $tg_token ) {
                if ( !$added[ $client.Name ] ) { $added[ $client.Name ] = @{} }
                if ( !$added[ $client.Name ][ $new_tracker_data.section ] ) { $added[ $client.Name ][ $new_tracker_data.section ] = @() }
                $added[ $client.Name][$new_tracker_data.section] += ( 'https://' + $forum.url + '/forum/viewtopic.php?t=' + $new_tracker_data.id )
            }
            $save_path = $section_details[$new_tracker_data.section][1]
            if ( $subfolder_kind -eq 1 ) {
                $save_path = ( $save_path -replace ( '\\$', '') -replace ( '/$', '') ) + '/' + $new_tracker_data.id # добавляем ID к имени папки для сохранения
            }
            elseif ( $subfolder_kind -eq 2 ) {
                $save_path = ( $save_path -replace ( '\\$', '') -replace ( '/$', '') ) + '/' + $new_torrent_key  # добавляем hash к имени папки для сохранения
            }
            $on_ssd = ( $ssd -and $save_path[0] -in $ssd[$section_details[$new_tracker_data.section][0]] )
            if ( $ssd -and $ssd[$section_details[$new_tracker_data.section][0]] ) {
                if ( $on_ssd -eq $false ) {
                    Set-ClientSetting $client 'temp_path' ( $ssd[$section_details[$new_tracker_data.section][0]][0] + ':\Incomplete' )
                    Set-ClientSetting $client 'temp_path_enabled' $true
                    Set-ClientSetting $client 'preallocate_all' $false
                }
                else {
                    Set-ClientSetting $client 'temp_path_enabled' $false
                    Set-ClientSetting $client 'preallocate_all' $false
                }
            }
            Add-ClientTorrent $client $new_torrent_file $save_path $section_details[$new_tracker_data.section][4]
            # if ( $on_ssd -eq $false) {
            #     Set-ClientSetting $client 'temp_path_enabled' $false
            #     Set-ClientSetting $client 'preallocate_all' $true
            # }
        }
        elseif ( !$existing_torrent -eq 'Y' -and $get_news -eq 'Y' -and $new_tracker_data.reg_time -ge ( ( Get-Date -UFormat %s ).ToInt32($nul) - $min_days * 86400 ) ) {
            Write-Output ( 'Раздача ' + $new_tracker_data.id + ' слишком новая.' )
        }
        elseif ( $get_news -eq 'N') {
            # раздача новая, но выбрано не добавлять новые. Значит ничего и не делаем.
        }
        else {
            Write-Host ( 'Случилось что-то странное на раздаче ' + $new_tracker_data.id + ' лучше остановимся' ) -ForegroundColor Red
            break
        }
    }
} # по наличию новых раздач.

Remove-Variable -Name obsolete -ErrorAction SilentlyContinue
if ( $nul -ne $tg_token -and '' -ne $tg_token -and $report_obsolete -and $report_obsolete -eq 'Y' ) {
    Write-Output 'Ищем неактуальные раздачи.'
    $obsolete_keys = $clients_tor_sort.Keys | Where-Object { !$tracker_torrents[$_] } | Where-Object { $refreshed_ids -notcontains $clients_tor_sort[$_] } | `
        Where-Object { $tracker_torrents.Values.id -notcontains $clients_tor_sort[$_] } | Where-Object { !$ignored_obsolete -or $nul -eq $ignored_obsolete[$clients_tor_sort[$_]] }
    $obsolete_torrents = $clients_torrents | Where-Object { $_.hash -in $obsolete_keys } | Where-Object { $_.topic_id -ne '' }
    $obsolete_torrents | ForEach-Object {
        If ( !$obsolete ) { $obsolete = @{} }
        Write-Output ( "Левая раздача " + $_.topic_id + ' в клиенте ' + $clients[$_.client_key].Name )
        if ( !$obsolete[$clients[$_.client_key].Name] ) { $obsolete[ $clients[$_.client_key].Name] = @() }
        $obsolete[$clients[$_.client_key].Name] += ( 'https://' + $forum.url + '/forum/viewtopic.php?t=' + $_.topic_id )
    }
}

# Очистим ненужные данные из памяти.
Remove-Variable -Name clients_tor_sort -ErrorAction SilentlyContinue
Remove-Variable -Name clients_tor_srt2 -ErrorAction SilentlyContinue

if ( $control -eq 'Y' ) {
    . "$PSScriptRoot\controller.ps1"
}

$report_flag_file = "$PSScriptRoot\report_needed.flg"
if ( ( $refreshed.Count -gt 0 -or $added.Count -gt 0 -or $obsolete.Count -gt 0 ) -and $update_stats -eq 'Y' -and $php_path ) {
    New-Item -Path $report_flag_file -ErrorAction SilentlyContinue | Out-Null
}
elseif ( $update_stats -ne 'Y' -or !$php_path ) {
    Remove-Item -Path $report_flag_file -ErrorAction SilentlyContinue | Out-Null
}

if ( ( $refreshed.Count -gt 0 -or $added.Count -gt 0 -or $obsolete.Count -gt 0 -or $notify_nowork -eq 'Y' ) -and $tg_token -ne '' -and $tg_chat -ne '' ) {
    Send-TGReport $refreshed $added $obsolete $tg_token $tg_chat
}

If ( Test-Path -Path $report_flag_file ) {
    if ( $refreshed.Count -gt 0 -or $added.Count -gt 0 ) {
        # что-то добавилось, стоит полождать.
        Update-Stats $true $true ( $send_reports -eq 'Y' ) # с паузой и проверкой условия по чётному времени.
    }
    else {
        Update-Stats $false $true ( $send_reports -eq 'Y'  ) # без паузы, так как это сработал флаг от предыдущего прогона. Но с проверкой по чётному времени.
    }
    Remove-Item -Path $report_flag_file -ErrorAction SilentlyContinue
}
