<#
    PSScriptAnalyzer-Einstellungen fuer RepairCenter.

    Zwei Regeln sind bewusst abgeschaltet - mit Begruendung, nicht aus
    Bequemlichkeit:

    PSAvoidUsingWriteHost
        RepairCenter ist ein Konsolenwerkzeug. Die farbige Ausgabe ist das
        Erzeugnis, nicht ein Nebeneffekt: sie landet im Transcript und ist
        fuer den Nutzer gedacht. Write-Output waere hier falsch, weil die
        Meldungen sonst in der Pipeline landen und Rueckgabewerte verfaelschen.

    PSReviewUnusedParameter
        Mehrere Parameter werden in verschachtelten Skriptbloecken ueber den
        Skript-Bereich benutzt; die Regel erkennt das nicht.

    Alles andere bleibt scharf gestellt - insbesondere
    PSUseShouldProcessForStateChangingFunctions, weil dieses Werkzeug
    Datentraeger loescht.
#>
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSReviewUnusedParameter'
    )
}
