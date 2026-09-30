// Ayudante de Aduana para macOS, en JavaScript for Automation (JXA).
//
// zsh no sabe leer JSON ni plist, y macOS ya no trae Python. JXA viene con el sistema desde 10.10
// y da acceso a Foundation, ImageIO y PDFKit sin instalar nada, así que las tareas que en zsh serían
// frágiles viven aquí. Cada subcomando lee de sus argumentos o de stdin y escribe texto plano con
// campos separados por tabuladores, que el script de zsh sabe partir.
//
// Uso: osascript -l JavaScript ayudante.js <subcomando> [argumentos]

ObjC.import('Foundation');

function leerStdin() {
  const datos = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
  return $.NSString.alloc.initWithDataEncoding(datos, $.NSUTF8StringEncoding).js || '';
}

function leerFichero(ruta) {
  const datos = $.NSData.dataWithContentsOfFile(ruta);
  if (datos.isNil()) throw new Error('No se puede leer ' + ruta);
  return $.NSString.alloc.initWithDataEncoding(datos, $.NSUTF8StringEncoding).js;
}

// Convierte un plist (XML o binario) leído de stdin en un objeto de JavaScript.
function plistDeStdin() {
  const datos = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
  if (datos.length === 0) return null;
  const error = $();
  const obj = $.NSPropertyListSerialization.propertyListWithDataOptionsFormatError(datos, 0, null, error);
  if (obj.isNil()) throw new Error('plist no válido');
  return ObjC.deepUnwrap(obj);
}

// Los campos no pueden llevar tabuladores ni saltos de línea, porque rompen el formato de salida.
function campo(valor) {
  return String(valor === undefined || valor === null ? '' : valor).replace(/[\t\r\n]/g, ' ');
}

const BASE64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function hexDeNSData(datos) {
  // JXA no expone los bytes de un NSData de forma directa, así que pasamos por base64.
  const b64 = datos.base64EncodedStringWithOptions(0).js.replace(/=+$/, '');
  let bits = 0, acumulado = 0, hex = '';
  for (const c of b64) {
    acumulado = (acumulado << 6) | BASE64.indexOf(c);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      hex += ((acumulado >> bits) & 0xff).toString(16).padStart(2, '0');
    }
  }
  return hex;
}

const subcomandos = {
  // Aplana reglas.json en líneas con una letra de tipo delante.
  reglas(argv) {
    const r = JSON.parse(leerFichero(argv[0]));
    const lineas = [];
    for (const e of r.extensiones) lineas.push(['E', e.ext, e.nivel, e.motivo].map(campo).join('\t'));
    for (const e of r.extensionesDocumento) lineas.push('D\t' + campo(e));
    for (const e of r.extensionesOffice) lineas.push('O\t' + campo(e));
    for (const e of r.artefactosSistema) lineas.push('A\t' + campo(e));
    for (const e of r.prefijosArtefacto) lineas.push('P\t' + campo(e));
    for (const c of r.caracteres.bidi) lineas.push('B\t' + campo(c));
    for (const c of r.caracteres.invisibles) lineas.push('I\t' + campo(c));
    for (const c of r.caracteres.puntosFalsos) lineas.push('F\t' + campo(c));
    for (const f of r.firmasEjecutables) lineas.push(['S', f.hex, f.tipo].map(campo).join('\t'));
    return lineas.join('\n');
  },

  // Primeros 8 bytes en hexadecimal de cada ruta recibida por stdin, separadas por NUL.
  // Responde una línea por ruta, en el mismo orden: el hex, «-» si está vacío o «!» si no se lee.
  magias() {
    const rutas = leerStdin().split('\0').filter((r) => r.length > 0);
    const salida = [];
    for (const ruta of rutas) {
      const fh = $.NSFileHandle.fileHandleForReadingAtPath(ruta);
      if (fh.isNil()) { salida.push('!'); continue; }
      const datos = fh.readDataOfLength(8);
      fh.closeFile;
      salida.push(datos.length === 0 ? '-' : hexDeNSData(datos));
    }
    return salida.join('\n');
  },

  // Extrae un campo de un JSON leído de stdin, con la ruta separada por puntos.
  'json-campo'(argv) {
    let valor = JSON.parse(leerStdin());
    for (const parte of argv[0].split('.')) {
      if (valor === null || valor === undefined) break;
      valor = valor[parte];
    }
    return campo(valor);
  },

  // Particiones de `diskutil list -plist <disco>`: identificador, contenido y punto de montaje.
  particiones() {
    const p = plistDeStdin();
    const lineas = [];
    for (const disco of (p && p.AllDisksAndPartitions) || []) {
      for (const part of disco.Partitions || []) {
        lineas.push([part.DeviceIdentifier, part.Content, part.MountPoint].map(campo).join('\t'));
      }
    }
    return lineas.join('\n');
  },

  // Valores de `diskutil info -plist` leído de stdin, uno por línea y en el orden pedido.
  'plist-campos'(argv) {
    const p = plistDeStdin() || {};
    return argv.map((k) => campo(p[k])).join('\n');
  },

  // Discos físicos que sostienen un volumen APFS, de `diskutil info -plist`.
  'almacenes-apfs'() {
    const p = plistDeStdin() || {};
    return (p.APFSPhysicalStores || []).map((a) => campo(a.APFSPhysicalStore)).join('\n');
  },

  // Discos enteros de `diskutil list -plist ...`.
  'discos-enteros'() {
    const p = plistDeStdin();
    return ((p && p.WholeDisks) || []).map(campo).join('\n');
  },

  // Recorre el árbol de `ioreg -a -r -c IOUSBHostDevice` buscando el dispositivo USB que contiene
  // el disco indicado, y lista lo que expone además del almacenamiento.
  usb(argv) {
    const disco = argv[0];
    const raiz = plistDeStdin();
    const dispositivos = Array.isArray(raiz) ? raiz : raiz ? [raiz] : [];

    function contieneDisco(nodo) {
      if (nodo['BSD Name'] === disco) return true;
      return (nodo.IORegistryEntryChildren || []).some(contieneDisco);
    }

    function recoger(nodo, info) {
      if (nodo.bInterfaceClass !== undefined) info.interfaces.push(nodo.bInterfaceClass);
      const clase = nodo.IOObjectClass || '';
      if (/^IO(CD|DVD|BD)Media$/.test(clase) || /CDROM|SCSIPeripheralDeviceType05/.test(clase)) info.cd = true;
      if (nodo['Peripheral Device Type'] === 5) info.cd = true;
      for (const hijo of nodo.IORegistryEntryChildren || []) recoger(hijo, info);
    }

    for (const d of dispositivos) {
      if (!contieneDisco(d)) continue;
      const info = { interfaces: [], cd: false };
      recoger(d, info);
      const lineas = [
        'fabricante\t' + campo(d['USB Vendor Name'] || d['kUSBVendorString'] || ''),
        'modelo\t' + campo(d['USB Product Name'] || d['kUSBProductString'] || ''),
        'vidpid\t' + campo((d.idVendor || 0).toString(16).padStart(4, '0') + ':' + (d.idProduct || 0).toString(16).padStart(4, '0')),
      ];
      for (const i of info.interfaces) lineas.push('interfaz\t' + i);
      if (info.cd) lineas.push('cd\t1');
      return lineas.join('\n');
    }
    return '';
  },

  // Metadatos personales de una imagen, con ImageIO.
  'imagen-leer'(argv) {
    ObjC.import('ImageIO');
    const fuente = $.CGImageSourceCreateWithURL($.NSURL.fileURLWithPath(argv[0]), null);
    if (!fuente) return 'error\tNo se puede abrir la imagen';
    const props = ObjC.deepUnwrap(ObjC.castRefToObject($.CGImageSourceCopyPropertiesAtIndex(fuente, 0, null))) || {};
    const tiff = props['{TIFF}'] || {};
    const exif = props['{Exif}'] || {};
    const lineas = [];
    if (props['{GPS}'] && Object.keys(props['{GPS}']).length > 0) lineas.push('gps\tubicación GPS');
    if (tiff.Make || tiff.Model) lineas.push('camara\t' + campo([tiff.Make, tiff.Model].filter(Boolean).join(' ')));
    if (tiff.Artist) lineas.push('autor\t' + campo(tiff.Artist));
    if (tiff.Software) lineas.push('software\t' + campo(tiff.Software));
    if (exif.DateTimeOriginal) lineas.push('fecha\t' + campo(exif.DateTimeOriginal));
    if (exif.BodySerialNumber || exif.LensSerialNumber) lineas.push('serie\tnúmero de serie de la cámara');
    return lineas.join('\n');
  },

  // Reescribe la imagen sin metadatos EXIF, GPS ni XMP, sin volver a comprimirla.
  'imagen-limpiar'(argv) {
    ObjC.import('ImageIO');
    const ruta = argv[0];
    const url = $.NSURL.fileURLWithPath(ruta);
    const fuente = $.CGImageSourceCreateWithURL(url, null);
    if (!fuente) return 'error\tNo se puede abrir la imagen';
    const tipo = $.CGImageSourceGetType(fuente);
    const temporal = ruta + '.aduana-tmp';
    const destino = $.CGImageDestinationCreateWithURL($.NSURL.fileURLWithPath(temporal), tipo, 1, null);
    if (!destino) return 'error\tFormato de imagen no soportado para limpiar';
    const opciones = $.NSMutableDictionary.alloc.init;
    opciones.setObjectForKey(ObjC.castRefToObject($.CGImageMetadataCreateMutable()), 'kCGImageDestinationMetadata');
    opciones.setObjectForKey($.NSNumber.numberWithBool(false), 'kCGImageDestinationMergeMetadata');
    opciones.setObjectForKey($.NSNumber.numberWithBool(true), 'kCGImageMetadataShouldExcludeGPS');
    opciones.setObjectForKey($.NSNumber.numberWithBool(true), 'kCGImageMetadataShouldExcludeXMP');
    const ok = $.CGImageDestinationCopyImageSource(destino, fuente, opciones, null);
    if (!ok) {
      $.NSFileManager.defaultManager.removeItemAtPathError(temporal, null);
      return 'error\tImageIO no pudo reescribir la imagen';
    }
    const fm = $.NSFileManager.defaultManager;
    fm.removeItemAtPathError(ruta, null);
    fm.moveItemAtPathToPathError(temporal, ruta, null);
    return 'ok';
  },

  // Metadatos del diccionario de información de un PDF, con PDFKit.
  'pdf-leer'(argv) {
    ObjC.import('PDFKit');
    const doc = $.PDFDocument.alloc.initWithURL($.NSURL.fileURLWithPath(argv[0]));
    if (doc.isNil()) return 'error\tNo se puede abrir el PDF';
    const attrs = ObjC.deepUnwrap(doc.documentAttributes) || {};
    const lineas = [];
    if (attrs.Author) lineas.push('autor\t' + campo(attrs.Author));
    if (attrs.Creator) lineas.push('creador\t' + campo(attrs.Creator));
    if (attrs.Producer) lineas.push('productor\t' + campo(attrs.Producer));
    return lineas.join('\n');
  },

  // Bloquea la sesión al momento. SACLockScreenImmediate es una función privada de
  // login.framework, la misma que usa el menú «Bloquear pantalla». Si desaparece en una versión
  // futura, el script de zsh recurre a apagar la pantalla.
  bloquear() {
    const marco = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/login.framework');
    if (marco.isNil() || !marco.load) return 'no';
    ObjC.bindFunction('SACLockScreenImmediate', ['int', []]);
    $.SACLockScreenImmediate();
    return 'ok';
  },
};

function run(argv) {
  const nombre = argv.shift();
  const f = subcomandos[nombre];
  if (!f) throw new Error('Subcomando desconocido: ' + nombre);
  return f(argv);
}
