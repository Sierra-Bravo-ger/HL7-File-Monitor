﻿# AnyFileMonitor (AFM) Hauptskript

# Konfig einlesen
$configPath = Join-Path $PSScriptRoot 'config.ini'
$config = @{}
Get-Content $configPath -Encoding default | Where-Object { $_ -match '=' -and -not $_.Trim().StartsWith('#') -and -not $_.Trim().StartsWith(';') } | ForEach-Object {
    $parts = $_ -split '=', 2
    $config[$parts[0].Trim()] = $parts[1].Trim()
}

# Debug-Ausgabe für die geladene Konfiguration
Write-Host "Geladene Konfiguration aus $configPath" -ForegroundColor Cyan

# Pfade aus Konfig
$inputPath = $config['inputPath']
$archivPath = $config['archivPath']
$errorPath = $config['errorPath']

# Logs aus Konfig
$statusLog = $config['AFMstatusLog']
$errorLog = $config['AFMerrorLog']
$seenList = $config['AFMseenList']
$inputDetailLog = $config['AFMinputDetailLog']

# Erweiterungen aus Konfig
$fileExtensions = @('.hl7', '.txt')  # Standardwerte falls nicht in Konfig definiert
if ($config.ContainsKey('fileExtensions')) {
    $fileExtensions = ($config['fileExtensions'] -split ',') | ForEach-Object { $_.Trim().ToLower() }
}

# RegEx-Ausdrücke für die Überwachung des Fehler-Logs
$errorPatterns = @()
if ($config.ContainsKey('errorPatterns')) {
    $errorPatterns = ($config['errorPatterns'] -split ',') | ForEach-Object { $_.Trim() }
    
    # Debug-Ausgabe der erkannten Muster
    Write-Host "Geladene Fehlermuster:" -ForegroundColor Cyan
    foreach ($pattern in $errorPatterns) {
        Write-Host "  - '$pattern'" -ForegroundColor Yellow
    }
}

# Ausnahme-Patterns aus config laden
$excludePatterns = @()
if ($config.ContainsKey('excludePatterns')) {
    $excludePatterns = ($config['excludePatterns'] -split ',') | ForEach-Object { $_.Trim() }
    
    # Debug-Ausgabe der Ausschluss-Muster
    if ($excludePatterns.Count -gt 0) {
        Write-Host "Geladene Ausschlussmuster:" -ForegroundColor Cyan
        foreach ($pattern in $excludePatterns) {
            Write-Host "  - '$pattern'" -ForegroundColor Yellow
        }
    }
}

# E-Mail-Konfiguration aus config.ini laden
$emailEnabled = $false
if ($config.ContainsKey('emailEnabled') -and $config['emailEnabled'] -eq 'true') {
    $emailEnabled = $true
    $emailSmtpServer = $config['emailSmtpServer']
    $emailSmtpPort = [int]$config['emailSmtpPort']
    $emailUseSSL = $config['emailUseSSL'] -eq 'true'
    $emailFrom = $config['emailFrom']
    $emailTo = ($config['emailTo'] -split ',') | ForEach-Object { $_.Trim() }
    $emailSubject = $config['emailSubject']
    $emailUsername = $config['emailUsername']
    $emailPassword = $config['emailPassword']
    $emailMinPatternMatches = [int]$config['emailMinPatternMatches']
    
    # Neue Konfiguration für Input-Threshold
    $emailInputThreshold = 0
    if ($config.ContainsKey('emailInputThreshold')) {
        $emailInputThreshold = [int]$config['emailInputThreshold']
    }
    
    # Neue Konfiguration für Inaktivitäts-Erkennung
    $emailNoActivityMinutes = 0
    if ($config.ContainsKey('emailNoActivityMinutes')) {
        $emailNoActivityMinutes = [int]$config['emailNoActivityMinutes']
    }
}

# WebHook-Konfiguration aus config.ini laden
$webhookEnabled = $false
if ($config.ContainsKey('WebHookEnabled') -and $config['WebHookEnabled'] -eq 'true') {
    $webhookEnabled = $true
    $webhookUrl = $config['WebHookUrl']
    
    # Verwende die gleichen Schwellwerte wie für E-Mail
    $webhookMinPatternMatches = $emailMinPatternMatches
    $webhookInputThreshold = $emailInputThreshold
    $webhookNoActivityMinutes = $emailNoActivityMinutes
}

# Funktion zum Senden von WebHook-Benachrichtigungen
function Send-WebhookNotification {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Title,
        
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$false)]
        [string]$Color = "#ff0000"  # Rot als Standardfarbe für Fehler
    )
    
    if (-not $webhookEnabled) {
        return
    }
    
    try {
        # Escape newlines for JSON compatibility and ensure proper Unicode handling
        $escapedMessage = $Message.Replace("\", "\\").Replace("`n", "\\n").Replace("`r", "\\r").Replace("`t", "\\t").Replace('"', '\"')
        $escapedTitle = $Title.Replace("\", "\\").Replace("`n", "\\n").Replace("`r", "\\r").Replace("`t", "\\t").Replace('"', '\"')
        
        # Convert hex color to decimal for Discord
        $colorDecimal = if ($Color -eq "#ff0000") { 16711680 } elseif ($Color -eq "#ffa500") { 16753920 } else { 5025616 }
        
        # Create JSON payload manually to ensure proper formatting
        $jsonPayload = @"
{
  "embeds": [
    {
      "title": "$escapedTitle",
      "description": "$escapedMessage",
      "color": $colorDecimal,
      "footer": {
        "text": "AnyFileMonitor - $timestamp"
      }
    }
  ]
}
"@
        
        # Senden der Webhook-Nachricht
        $params = @{
            Uri = $webhookUrl
            Method = 'POST'
            Body = $jsonPayload
            ContentType = 'application/json; charset=UTF-8'
        }
        
        Invoke-RestMethod @params
        
        Write-Host "Webhook-Benachrichtigung wurde gesendet: $Title" -ForegroundColor Cyan
    }
    catch {
        Write-Host "Fehler beim Senden der Webhook-Benachrichtigung: $_" -ForegroundColor Red
        Write-Host "Payload: $jsonPayload" -ForegroundColor DarkGray
    }
}

# Pfad für das Muster-Log (Treffer der RegEx-Ausdrücke)
$patternLogPath = Join-Path $PSScriptRoot "AFM_pattern_matches.csv"

# Sicherstellen, dass Logdateien existieren
if (!(Test-Path $statusLog)) {
    "Zeitpunkt;Input;Archiv;Error" | Out-File -FilePath $statusLog -Encoding utf8
}
if (!(Test-Path $errorLog)) {
    "Zeitpunkt;ErrorDatei;Fehlermeldung;EXTDatei;EXTInhalt" | Out-File -FilePath $errorLog -Encoding utf8
}
if (!(Test-Path $seenList)) {
    New-Item $seenList -ItemType File -Force | Out-Null
}
if (!(Test-Path $inputDetailLog)) {
    "Zeitpunkt;Anzahl;Dateinamen als String" | Out-File -FilePath $inputDetailLog -Encoding utf8
}

# Vorher gesehene Dateien laden (für Error-Verarbeitung)
$seen = @()
if (Test-Path $seenList) {
    $seen = Get-Content $seenList
}

# Zeitstempel für Logeintrag
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# INPUT-Ordner: Dateien zählen ohne zu modifizieren
$inputFiles = Get-ChildItem -Path $inputPath -File -ErrorAction SilentlyContinue | 
              Where-Object { $fileExtensions -contains $_.Extension.ToLower() }
$inputCount = $inputFiles.Count

# Prüfen, ob der Input-Threshold überschritten wurde und eine E-Mail senden, wenn nötig
if ($emailEnabled -and $emailInputThreshold -gt 0 -and $inputCount -gt $emailInputThreshold) {
    try {
        # E-Mail-Inhalt für verzögerte Verarbeitung erstellen
        $emailBodyDelayed = @"
Hallo,

das AnyFileMonitor-Skript hat $inputCount Dateien im $inputPath gefunden.

Dies deutet normalerweise auf verzoegerte Bearbeitung hin.

Mit freundlichen Gruessen,
Ihr AnyFileMonitor
"@
        
        if ($emailUsername -and ($emailPassword -and $emailPassword.Trim() -ne "")) {
        # Benutzername und Passwort vorhanden, Anmeldeinformationen erstellen
        $securePassword = ConvertTo-SecureString $emailPassword -AsPlainText -Force
        $credentials = New-Object System.Management.Automation.PSCredential ($emailUsername, $securePassword)
        } elseif ($emailUsername) {
        # Nur Benutzername vorhanden, leeres Passwort verwenden
        $securePassword = ConvertTo-SecureString "" -AsPlainText -Force
        $credentials = New-Object System.Management.Automation.PSCredential ($emailUsername, $securePassword)
        } else {
        # Weder Benutzername noch Passwort vorhanden, keine Anmeldeinformationen
        $credentials = $null
        }
        
        # E-Mail-Parameter
        $mailParams = @{
            SmtpServer = $emailSmtpServer
            Port = $emailSmtpPort
            UseSsl = $emailUseSSL
            From = $emailFrom
            To = $emailTo
            Subject = "Verzoegerte Verarbeitung"
            Body = $emailBodyDelayed
        }
        
        # Anmeldeinformationen nur hinzufügen, wenn sie existieren
        if ($credentials) {
            $mailParams.Credential = $credentials
        }
        
        # E-Mail senden
        Send-MailMessage @mailParams
        
        Write-Host "E-Mail über verzögerte Verarbeitung wurde gesendet: $inputCount Dateien im Input-Ordner." -ForegroundColor Yellow
    }
    catch {
        Write-Host "Fehler beim Senden der E-Mail über verzögerte Verarbeitung: $_" -ForegroundColor Red
    }
    
    # Auch Webhook-Benachrichtigung senden, wenn aktiviert
    if ($webhookEnabled -and $webhookInputThreshold -gt 0 -and $inputCount -gt $webhookInputThreshold) {
        $webhookMessage = "Das AnyFileMonitor-Skript hat $inputCount Dateien im $inputPath gefunden.`n`nDies deutet normalerweise auf verzögerte Bearbeitung hin."
        Send-WebhookNotification -Title "Verzögerte Verarbeitung" -Message $webhookMessage -Color "#ffa500"  # Orange für Warnungen
    }
}

# Prüfen auf Inaktivität (keine neuen Dateien verarbeitet seit X Minuten)
if ($emailEnabled -and $emailNoActivityMinutes -gt 0) {
    try {
        $mostRecentFile = Get-ChildItem -Path $archivPath -File -ErrorAction SilentlyContinue | 
                           Sort-Object LastWriteTime -Descending | 
                           Select-Object -First 1
        
        if ($mostRecentFile) {
            $lastFileTime = $mostRecentFile.LastWriteTime
            $inactiveTime = (Get-Date) - $lastFileTime
            $inactiveMinutes = $inactiveTime.TotalMinutes
            
            Write-Host "Letzte Dateiverschiebung vor $([Math]::Round($inactiveMinutes, 2)) Minuten." -ForegroundColor Cyan
            
            if ($inactiveMinutes -gt $emailNoActivityMinutes) {
                # E-Mail-Inhalt für Inaktivitätswarnung erstellen
                $emailBodyInactivity = @"
Hallo,

das AnyFileMonitor-Skript hat festgestellt, dass seit $([Math]::Round($inactiveMinutes, 0)) Minuten keine Dateien mehr verarbeitet wurden.
(Schwellwert: $emailNoActivityMinutes Minuten)

Die letzte Datei wurde am $($lastFileTime.ToString("yyyy-MM-dd HH:mm:ss")) verarbeitet.
Bitte prüfen Sie, ob es Probleme mit der Dateiverarbeitung gibt.

Mit freundlichen Grüssen,
Ihr AnyFileMonitor
"@
                
                if ($emailUsername -and ($emailPassword -and $emailPassword.Trim() -ne "")) {
                    # Benutzername und Passwort vorhanden, Anmeldeinformationen erstellen
                    $securePassword = ConvertTo-SecureString $emailPassword -AsPlainText -Force
                    $credentials = New-Object System.Management.Automation.PSCredential ($emailUsername, $securePassword)
                } elseif ($emailUsername) {
                    # Nur Benutzername vorhanden, leeres Passwort verwenden
                    $securePassword = ConvertTo-SecureString "" -AsPlainText -Force
                    $credentials = New-Object System.Management.Automation.PSCredential ($emailUsername, $securePassword)
                } else {
                    # Weder Benutzername noch Passwort vorhanden, keine Anmeldeinformationen
                    $credentials = $null
                }
                
                # E-Mail-Parameter
                $mailParams = @{
                    SmtpServer = $emailSmtpServer
                    Port = $emailSmtpPort
                    UseSsl = $emailUseSSL
                    From = $emailFrom
                    To = $emailTo
                    Subject = "Inaktivitätswarnung: Keine Dateien verarbeitet"
                    Body = $emailBodyInactivity
                }
                
                # Anmeldeinformationen nur hinzufügen, wenn sie existieren
                if ($credentials) {
                    $mailParams.Credential = $credentials
                }
                
                # E-Mail senden
                Send-MailMessage @mailParams
                
                Write-Host "E-Mail über Inaktivität wurde gesendet: Keine Dateien seit $([Math]::Round($inactiveMinutes, 0)) Minuten verarbeitet." -ForegroundColor Yellow
                
                # Auch Webhook-Benachrichtigung senden, wenn aktiviert
                if ($webhookEnabled -and $webhookNoActivityMinutes -gt 0 -and $inactiveMinutes -gt $webhookNoActivityMinutes) {
                    $webhookMessage = "Das AnyFileMonitor-Skript hat festgestellt, dass seit $([Math]::Round($inactiveMinutes, 0)) Minuten keine Dateien mehr verarbeitet wurden.`n(Schwellwert: $webhookNoActivityMinutes Minuten)`n`nDie letzte Datei wurde am $($lastFileTime.ToString("yyyy-MM-dd HH:mm:ss")) verarbeitet.`nBitte prüfen Sie, ob es Probleme mit der Dateiverarbeitung gibt."
                    Send-WebhookNotification -Title "Inaktivitätswarnung: Keine Dateien verarbeitet" -Message $webhookMessage -Color "#ffa500"  # Orange für Warnungen
                }
            }
        } else {
            Write-Host "Warnung: Keine Dateien im Archiv-Ordner gefunden." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "Fehler bei der Inaktivitätsprüfung: $_" -ForegroundColor Red
    }
}

# Optimierung: Nur die ersten 5 Dateien für die CSV-Datei verwenden
$inputFileNamesForLog = ""
if ($inputCount -gt 0) {
    # Begrenzen auf maximal 5 Dateien, um CSV-Größe zu reduzieren
    $samplesToShow = [Math]::Min(5, $inputCount)
    $filenameSamples = $inputFiles | Select-Object -First $samplesToShow | Select-Object -ExpandProperty Name
    
    if ($inputCount -le $samplesToShow) {
        $inputFileNamesForLog = $filenameSamples -join ','
    } else {
        # Bei mehr als 5 Dateien werden nur Beispiele angezeigt
        $inputFileNamesForLog = ($filenameSamples -join ',') + "... (und $($inputCount - $samplesToShow) weitere)"
    }
}

# ARCHIV-Ordner: Dateien zählen
$archivFiles = Get-ChildItem -Path $archivPath -File -ErrorAction SilentlyContinue
$archivCount = $archivFiles.Count

# ERROR-Ordner: Dateien zählen
$errorFiles = Get-ChildItem -Path $errorPath -File -ErrorAction SilentlyContinue
$errorCount = $errorFiles.Count

# Status-Log aktualisieren
"$timestamp;$inputCount;$archivCount;$errorCount" | Out-File -Append -FilePath $statusLog -Encoding utf8

# Input-Detail-Log aktualisieren
"$timestamp;$inputCount;$inputFileNamesForLog" | Out-File -Append -FilePath $inputDetailLog -Encoding utf8

# Nachträgliche Fehlerverarbeitung (nur für Dateien, die noch nicht gesehen wurden und älter als 1 Minute sind)

# Alle Dateien im Error-Ordner sammeln, die den konfigurierten Erweiterungen entsprechen und älter als 1 Minute sind
$allFilesForProcessing = Get-ChildItem -Path $errorPath -File -ErrorAction SilentlyContinue | 
                        Where-Object { 
                            $fileExtensions -contains $_.Extension.ToLower() -and 
                            $_.LastWriteTime -lt (Get-Date).AddMinutes(-1) 
                        }

# Dateien nach Typ filtern
$errorFilesForProcessing = $allFilesForProcessing | Where-Object { $_.Extension.ToLower() -eq ".error" }
$extFilesForProcessing = $allFilesForProcessing | Where-Object { $_.Extension.ToLower() -eq ".ext" }
$otherFilesForProcessing = $allFilesForProcessing | Where-Object { 
    $_.Extension.ToLower() -ne ".error" -and $_.Extension.ToLower() -ne ".ext" 
}

# Liste für bereits verarbeitete .ext-Dateien
$processedExtFiles = @()

# Liste für gefundene Muster
$patternMatches = @()

# Verarbeitung von .error-Dateien (mit oder ohne zugehörige .ext-Dateien)
foreach ($errFile in $errorFilesForProcessing) {
    if ($seen -contains $errFile.Name) { continue }
    
    try {
        $errorFilename = $errFile.Name
        $basename = [System.IO.Path]::GetFileNameWithoutExtension($errorFilename)
        
        # .error-Datei lesen
        $errorText = Get-Content $errFile.FullName -ErrorAction Stop | Out-String
        $errorText = $errorText.Trim().Replace("`r`n", " ")
        if ($errorText.Length -gt 1500) { $errorText = $errorText.Substring(0,1500) }

        # Zugehörige .ext-Datei suchen und lesen
        $extFilename = "$basename.ext"
        $extPath = Join-Path $errorPath $extFilename
        $extText = ""
        
        if (Test-Path $extPath) {
            $extText = Get-Content $extPath -ErrorAction Stop | Out-String
            $extText = $extText.Trim().Replace("`r`n", " ")
            if ($extText.Length -gt 1500) { $extText = $extText.Substring(0,1500) }
            # Merken, dass diese .ext-Datei bereits verarbeitet wurde
            $processedExtFiles += $extFilename
        } else {
            $extText = "[Keine ext-Datei gefunden]"
        }

        # Fehlerlog schreiben
        "$timestamp;$errorFilename;$errorText;$extFilename;$extText" | Out-File -FilePath $errorLog -Append -Encoding utf8

        # Bei der Musterprüfung mit verbessertem Debugging
        foreach ($pattern in $errorPatterns) {
            # Debug-Ausgabe für den aktuellen Text und das Muster
            Write-Host "Prüfe Muster: '$pattern' gegen Text: '$errorText'" -ForegroundColor DarkGray
            
            # Erweiterte Prüfung mit mehreren Methoden
            $containsMatch = $errorText.Contains($pattern)
            $indexMatch = $errorText.IndexOf($pattern)
            
            Write-Host "  Contains: $containsMatch, Index: $indexMatch" -ForegroundColor DarkGray
            
            if ($containsMatch -or $indexMatch -ge 0) {
                Write-Host "  TREFFER GEFUNDEN für Muster: '$pattern' in: '$errorText'" -ForegroundColor Green
                
                # Prüfen, ob eine Ausnahme zutrifft
                $isExcluded = $false
                foreach ($excludePattern in $excludePatterns) {
                    if ($errorText.Contains($excludePattern)) {
                        $isExcluded = $true
                        Write-Host "  AUSSCHLUSS durch Muster: '$excludePattern'" -ForegroundColor Yellow
                        break
                    }
                }
                
                # Nur wenn keine Ausnahme zutrifft, als Treffer zählen
                if (-not $isExcluded) {
                    $patternMatches += [PSCustomObject]@{
                        Zeitpunkt = $timestamp
                        Datei = $errorFilename
                        Muster = $pattern
                        Text = $errorText
                    }
                    Write-Host "  Muster wird als Treffer gezählt!" -ForegroundColor Green
                    break  # Ein Treffer pro Datei reicht
                }
            }
        }

        # Gesehen-Liste aktualisieren
        Add-Content $seenList $errorFilename
    }
    catch {
        Write-Host "Warnung: Fehler beim Verarbeiten von $($errFile.Name) - $_"
    }
}

# Verarbeitung von .ext-Dateien ohne zugehörige .error-Dateien
foreach ($extFile in $extFilesForProcessing) {
    $extFilename = $extFile.Name
    
    # Überspringen, wenn die .ext-Datei bereits verarbeitet wurde oder in der gesehen-Liste ist
    if ($processedExtFiles -contains $extFilename -or $seen -contains $extFilename) { continue }
    
    $basename = [System.IO.Path]::GetFileNameWithoutExtension($extFilename)
    $errorFilename = "$basename.error"
    $errorFilePath = Join-Path $errorPath $errorFilename  # Variable umbenannt, um Überschreibung zu vermeiden
    
    # Nur verarbeiten, wenn keine zugehörige .error-Datei existiert
    if (Test-Path $errorFilePath) { continue }
    
    try {
        # .ext-Datei lesen
        $extText = Get-Content $extFile.FullName -ErrorAction Stop | Out-String
        $extText = $extText.Trim().Replace("`r`n", " ")
        if ($extText.Length -gt 1500) { $extText = $extText.Substring(0,1500) }

        # Fehlerlog schreiben
        "$timestamp;[Keine error-Datei gefunden];[Kein Fehlertext verfügbar];$extFilename;$extText" | Out-File -FilePath $errorLog -Append -Encoding utf8

        # Gesehen-Liste aktualisieren
        Add-Content $seenList $extFilename
    }
    catch {
        Write-Host "Warnung: Fehler beim Verarbeiten von $($extFile.Name) - $_"
    }
}

# Verarbeitung anderer Dateitypen (nicht .error oder .ext)
foreach ($otherFile in $otherFilesForProcessing) {
    if ($seen -contains $otherFile.Name) { continue }
    
    try {
        $filename = $otherFile.Name
        # Datei lesen
        $fileContent = Get-Content $otherFile.FullName -ErrorAction Stop | Out-String
        $fileContent = $fileContent.Trim().Replace("`r`n", " ")
        if ($fileContent.Length -gt 1500) { $fileContent = $fileContent.Substring(0,1500) }
        
        # Fehlerlog schreiben
        "$timestamp;[Keine error-Datei gefunden];[Kein Fehlertext verfügbar];$filename;$fileContent" | Out-File -FilePath $errorLog -Append -Encoding utf8
        
        # Prüfen, ob der Dateiinhalt einen der konfigurierten RegEx-Ausdrücke enthält
        foreach ($pattern in $errorPatterns) {
            if ($fileContent -match $pattern) {
                $patternMatches += [PSCustomObject]@{
                    Zeitpunkt = $timestamp
                    Datei = $filename
                    Muster = $pattern
                    Text = $fileContent
                }
                break  # Ein Treffer pro Datei reicht
            }
        }
        
        # Gesehen-Liste aktualisieren
        Add-Content $seenList $filename
    }
    catch {
        Write-Host "Warnung: Fehler beim Verarbeiten von $($otherFile.Name) - $_"
    }
}

# Muster-Log aktualisieren, falls Treffer gefunden wurden
if ($patternMatches.Count -gt 0) {
    # Überschrift erstellen, falls die Datei noch nicht existiert
    if (!(Test-Path $patternLogPath)) {
        "Zeitpunkt;Datei;Muster;Text" | Out-File -FilePath $patternLogPath -Encoding utf8
    }
    
    # Treffer ins Log schreiben
    foreach ($match in $patternMatches) {
        "$($match.Zeitpunkt);$($match.Datei);$($match.Muster);$($match.Text)" | Out-File -FilePath $patternLogPath -Append -Encoding utf8
    }
    
    # Ausgabe der Anzahl gefundener Muster
    Write-Host "Es wurden $($patternMatches.Count) Muster in den Fehlertexten gefunden."
    
    # E-Mail senden, wenn aktiviert und genügend Muster gefunden wurden
    if ($emailEnabled -and $patternMatches.Count -ge $emailMinPatternMatches) {
        try {
            # E-Mail-Inhalt erstellen
            $emailBody = @"
Hallo,

das AnyFileMonitor-Skript hat $($patternMatches.Count) Muster in den Fehlertexten gefunden.

Details zu den gefundenen Mustern:

"@
            
            # Die ersten 10 Muster (oder alle, wenn weniger) in den E-Mail-Text einfügen
            $maxDetailsToShow = [Math]::Min(10, $patternMatches.Count)
            for ($i = 0; $i -lt $maxDetailsToShow; $i++) {
                $match = $patternMatches[$i]
                $emailBody += @"

Datei: $($match.Datei)
Muster: $($match.Muster)
Text: $($match.Text)
Zeitpunkt: $($match.Zeitpunkt)
-------------------------------
"@
            }
            
            if ($patternMatches.Count -gt 10) {
                $emailBody += @"

... und $(($patternMatches.Count) - 10) weitere Treffer.

"@
            }
            
            $emailBody += @"

Mit freundlichen Grueßen,
Ihr AnyFileMonitor
"@
            
            # Sichere Anmeldeinformationen erstellen
            $securePassword = ConvertTo-SecureString $emailPassword -AsPlainText -Force
            $credentials = New-Object System.Management.Automation.PSCredential ($emailUsername, $securePassword)
            
            # E-Mail-Parameter
            $mailParams = @{
                SmtpServer = $emailSmtpServer
                Port = $emailSmtpPort
                UseSsl = $emailUseSSL
                From = $emailFrom
                To = $emailTo
                Subject = "$emailSubject ($($patternMatches.Count) Muster gefunden)"
                Body = $emailBody
                Credential = $credentials
            }
            
            # E-Mail senden
            Send-MailMessage @mailParams
            
            Write-Host "E-Mail mit Fehlerdetails wurde gesendet."
        }
        catch {
            Write-Host "Fehler beim Senden der E-Mail: $_"
        }
        
        # Auch Webhook-Benachrichtigung senden, wenn aktiviert
        if ($webhookEnabled -and $patternMatches.Count -ge $webhookMinPatternMatches) {
            # Webhook-Nachricht erstellen
            $webhookMessage = "Das AnyFileMonitor-Skript hat $($patternMatches.Count) Muster in den Fehlertexten gefunden.`n`nDetails zu den gefundenen Mustern:`n`n"
            
            # Die ersten 5 Muster (oder alle, wenn weniger) in die Webhook-Nachricht einfügen
            $maxDetailsToShow = [Math]::Min(5, $patternMatches.Count)  # Begrenzen auf 5 für Discord
            for ($i = 0; $i -lt $maxDetailsToShow; $i++) {
                $match = $patternMatches[$i]
                $webhookMessage += "**Datei:** $($match.Datei)`n"
                $webhookMessage += "**Muster:** $($match.Muster)`n"
                $webhookMessage += "**Zeitpunkt:** $($match.Zeitpunkt)`n"
                $webhookMessage += "-------------------------------`n"
            }
            
            if ($patternMatches.Count -gt 5) {
                $webhookMessage += "`n... und $(($patternMatches.Count) - 5) weitere Treffer."
            }
            
            Send-WebhookNotification -Title "$emailSubject ($($patternMatches.Count) Muster gefunden)" -Message $webhookMessage -Color "#ff0000"  # Rot für Fehler
        }
    }
}

Write-Host "AFM abgeschlossen."