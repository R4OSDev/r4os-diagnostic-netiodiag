NETIOD.R4X
==========

NETIOD.R4X ist die R4NET-Socket-Completion-Diagnose.

Seit 0.55.7 prueft NETIOD zusaetzlich die Connectivity-kritischen
R4NET-Vertraege: Statusnamen, Socket-Lifecycle-Namen, TCP-Grenzen und
queue-basierte TCPSVC-Endpoint-Details. Erfolgreiche Abnahme meldet
`NETIOD connectivity-contract: OK` und `NETIOD tcp-service-workers: OK`.

Projektstruktur seit 0.51.21:
- `build.zig` baut die Diagnose als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad, R4L-Imports und Contract.

Build:

    cd Code\System\Diagnostics\NetIoDiag
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Diagnostics\NetIoDiag\zig-out\NETIOD.R4X

Contract:
- Build-Profil: `Zig/R4XStart`
- R4XStart-Entry: `netiod_main`
- App-Klasse: `console`
- R4L-Imports: `R4NET`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\TERMINAL\DIAG\NETIOD.R4X`
