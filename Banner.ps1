#Settings
$ipfilter_path = 'L:\Software\RT_Adder\ipfiler.dat'
$ipfilter_source = 'https://bot.keeps.cyou/static/ipfilter.dat'

# Code

Test-Version ( $PSCommandPath | Split-Path -Leaf )
Test-Version ( '_functions.ps1' )

if ( -not ( [bool](Get-InstalledModule -Name PsIni -ErrorAction SilentlyContinue) ) ) {
    Write-Output 'Не установлен модуль PSIni для чтения настроек Web-TLO, ставим...'
    Install-Module -Name PsIni -Scope CurrentUser -Force
}

If ( -not ( Test-Path "$PSScriptRoot\_settings.ps1" ) ) {
    Set-Preferences
}
else { . "$PSScriptRoot\_settings.ps1" }

Write-Output 'Скачиваем файл'
$new_path = $ipfilter_path -replace '\..+?$', '.new'
Invoke-WebRequest -Uri $ipfilter_source -OutFile $new_path
if ( ( Get-FileHash -Path $ipfilter_path ).Hash -ne ( Get-FileHash -Path $new_path).Hash ) {
    Write-Output 'Файл обновился, перечитываем'
    $use_timestamp = 'N'
    Write-Output 'Подгружаем функции'
    . "$PSScriptRoot\_functions.ps1"
    Write-Output 'Читаем настройки Web-TLO'
    $ini_path = $tlo_path + '\data\config.ini'
    $ini_data = Get-IniContent $ini_path
    $clients = Get-Clients
    Move-Item -Path $ipfilter_path -Destination $new_path -Force
    foreach ( $client_key in $clients.Keys ) {
        Initialize-Client $clients[$client_key]
        Write-Output ( 'Обновляем фильтр в клиенте ' + $clients[$client_key].Name )
        Switch-Filtering $clients[$client_key] $false
        Start-Sleep -Seconds 1
        Switch-Filtering $clients[$client_key] $true
    }
}
else {
    Write-Output 'Файл не изменился'
    Remove-Item $new_path -Force
}
Write-Output 'Готово'
 