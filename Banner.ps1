#Settings
$ipfilter_path = 'L:\Software\RT_Adder\ipfiler.dat'
$ipfilter_source = 'https://bot.keeps.cyou/static/ipfilter.dat'

# Code
Write-Output 'Подгружаем функции'
. "$PSScriptRoot\_functions.ps1"

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

$clients = Get-Clients

Write-Output 'Скачиваем файл'
Invoke-WebRequest -Uri $ipfilter_source -OutFile $ipfilter_path

foreach ( $client_key in $clients.Keys ) {
    Initialize-Client $clients[$client_key]
    Write-Output ( 'Обновляем фильтр в клиенте ' + $clients[$client_key].Name )
    Switch-Filtering $clients[$client_key] $false
    Start-Sleep -Seconds 1
    Switch-Filtering $clients[$client_key] $true
 }

 Write-Output 'Готово'