# DJ Library

Editor para la biblioteca de Engine DJ: corrige BPM (y el beatgrid), artista/título, álbum y carátula,
guardando a la vez en la base de datos de Engine y en los tags del archivo (ID3 / M4A).

## Uso

```
./build-app.sh
open "build/DJ Library.app"
```

- **Barra lateral:** playlists de Engine. También puedes arrastrar archivos o carpetas a la ventana.
- **BPM:** ÷2, ×2, redondear o fijar un valor. El beatgrid ajustado se reescribe como grid constante
  manteniendo el beat 0; el grid del análisis no se toca, así **RESET** en Engine lo restaura.
- **Artista/Título desde nombre:** quita prefijos tipo `085 `, `(092) `, `100. `, `[Género] - ` y el sufijo `99 BPM`.
- **Carátula:** elige tu logo en Ajustes (⌘,). Se embebe en el archivo y Engine la reconoce por su SHA1.
- **Seleccionar sospechosos:** BPM > 140, < 70 o con decimales.
- Los cambios quedan en naranja hasta pulsar **Guardar** (⌘S).

## Motor de BPM (Analizar BPM)

`TempoDetector` (DJCore) está pensado para música de DJ:
- BPM **enteros** (edits y remixes casi siempre lo son) en el rango 70–165.
- **Cambios de tempo** (transiciones 128→98, 100→150…): puntuación por ventanas de 8 s y camino de Viterbi
  que penaliza cambiar; se limpian tramos falsos (breaks a medio tiempo, tresillos 3:2).
- Curva de ataques con más peso a los **graves** (el bombo marca el beat; la percusión del dembow engaña).
- **Fase** con corrección de la latencia del FFT y **compás** = primer golpe fuerte del tramo.
- Grid de Engine con un marcador por tramo y un "puente" corto entre tramos para que el 1 caiga en su sitio.

Banco de pruebas (`swift run -c release djcheck bpmtest <carpeta>`), con el BPM de los nombres de archivo:
Transition 100/108 (los fallos son en su mayoría nombres inexactos), 2026 53/54.
`djcheck gridtest <EngineLibrary> <carpeta>` compara con el grid de Engine: compás igual en 59/63, fase ±4 ms (mediana).

## rekordbox y pendrive

Engine es la biblioteca principal; rekordbox solo recibe.

- `~/Library/Pioneer/rekordbox/rekordbox.xml` se regenera solo: al arrancar si está viejo, al guardar,
  y cuando cambia la base de Engine (se vigila cada 10 s). Incluye playlists, beatgrid, hot cues
  (también como memory cues), cue principal y loops.
- Menú **rekordbox → Configurar** (con rekordbox cerrado) apunta rekordbox a ese XML y activa
  «rekordbox xml» en su barra lateral. Deja copia en `rekordbox3.settings.djlibrary-backup`.
- Pendrive: en rekordbox, «rekordbox xml» → clic derecho en la playlist → **Importar playlist**,
  y después arrastrarla al pendrive (o clic derecho → Exportar).

## Seguridad

- Engine DJ tiene que estar cerrado para guardar.
- Antes del primer guardado de cada sesión se copia `m.db` a `Engine Library/DJLibrary Backups/`.
  Para volver atrás: cerrar Engine y copiar esa copia sobre `Engine Library/Database2/m.db`.
- Los archivos se reescriben sobre sí mismos (sin cambiar de ID en Google Drive).

## Formato de Engine (Database2/m.db)

- `Track.bpm` / `Track.bpmAnalyzed`, `title`, `artist`, `album`, `albumArtId`, `fileBytes`.
- `AlbumArt.hash` = SHA1 de la imagen embebida (el blob va vacío; Engine lee la imagen del archivo).
- `PerformanceData.beatData`: qCompress (4 bytes BE de longitud + zlib) de
  `sampleRate f64 BE, totalSamples f64 BE, isSet u8, gridDefecto, gridAjustado, cola`;
  cada grid es `count i64 BE` + markers `pos f64 LE, beat i64 LE, beatsHastaSiguiente i32 LE, ? i32 LE`.

`djcheck` (`swift run djcheck …`) sirve para probar el núcleo sobre **copias** de la base y de los archivos.
