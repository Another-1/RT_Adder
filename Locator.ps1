# # Code
# $str = 'Подгружаем функции' 
# if ( $use_timestamp -ne 'Y' ) { Write-Host $str } else { Write-Host ( ( Get-Date -Format 'dd-MM-yyyy HH:mm:ss' ) + ' ' + $str ) }
# . "$PSScriptRoot\_functions.ps1"

# if ( ( ( get-process | Where-Object { $_.ProcessName -eq 'pwsh' } ).CommandLine -like '*Locator.ps1').count -gt 1 ) {
#     Write-Host 'Я и так уже выполняюсь, выходим' -ForegroundColor Red
#     exit
# }

# Write-Log 'Проверяем версию Powershell...'
# If ( $PSVersionTable.PSVersion -lt [version]'7.1.0.0') {
#     Write-Host 'У вас слишком древний Powershell, обновитесь с https://github.com/PowerShell/PowerShell#get-powershell ' -ForegroundColor Red
#     Pause
#     Exit
# }

# if ( -not ( [bool](Get-InstalledModule -Name PsIni -ErrorAction SilentlyContinue) ) ) {
#     Write-Log 'Не установлен модуль PSIni для чтения настроек Web-TLO, ставим...'
#     Install-Module -Name PsIni -Scope CurrentUser -Force
# }

# If ( -not ( Test-path "$PSScriptRoot\_settings.ps1" )) {
#     Set-Preferences # $tlo_path $max_seeds $get_hidden $get_blacklist $get_news $tg_token $tg_chat
# }
# else { . "$PSScriptRoot\_settings.ps1" }

# Write-Log 'Читаем настройки Web-TLO'
# $ini_path = $tlo_path + '\data\config.ini'
# $ini_data = Get-IniContent $ini_path

# Write-Log 'Получаем из TLO данные о клиентах'
# $clients = @{}
# $client_count = $ini_data['other'].qt.ToInt16($null)
# Write-Log "Актуальных клиентов к обработке: $client_count"
# $i = 1
# $ini_data.keys | Where-Object { $_ -match '^torrent-client' -and $ini_data[$_].client -eq 'qbittorrent' } | ForEach-Object {
#     if ( ( $_ | Select-String ( '\d+$' ) ).matches.value.ToInt16($null) -le $client_count ) {
#         # Write-Output "Учитываем клиент $i"
#         $clients[$ini_data[$_].id] = @{ Login = $ini_data[$_].login; Password = $ini_data[$_].password; Name = $ini_data[$_].comment; IP = $ini_data[$_].hostname; Port = $ini_data[$_].port; }
#         $i++
#     }
# } 

# $clients_torrents = @()

# foreach ($clientkey in $clients.Keys ) {
#     $client = $clients[ $clientkey ]
#     Initialize-Client( $client )
#     $client_torrents = Get-Torrents $client '' $true $null $clientkey
#     $clients_torrents += $client_torrents
# }

$paths = @{}
$cnt = 0
foreach ( $torrent in $client_torrents ) {
    $cnt++
    Write-Progress -Activity 'Ищу' -Status $torrent.name -PercentComplete ( $cnt * 100 / $client_torrents.Count )
    if (!$paths[$torrent.content_path] ) { $paths[$torrent.content_path] = $torrent.name }
    else {
        Write-Output '-------------------------------'
        Write-Output $torrent.content_path
        Write-Output $paths[$torrent.content_path]
        Write-Output $torrent.name
        Write-Output '-------------------------------'
    }
}
Write-Progress -Activity 'Ищу' -Completed
