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
