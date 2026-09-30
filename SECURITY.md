# Política de seguridad

## Cómo avisar de una vulnerabilidad

No abras una issue pública. Usa el aviso privado de GitHub desde la pestaña
[Security](https://github.com/jmortegac/Aduana/security/advisories/new) del repositorio.

Cuenta qué versión usas, en qué sistema, y cómo reproducirlo. Respondo en un plazo de siete días.

## Qué cuenta como vulnerabilidad

- Un fichero o un dispositivo que Aduana da por limpio y que ejecuta código al abrirlo, siempre que
  el caso esté dentro de lo que Aduana dice revisar.
- Cualquier forma de que `inspeccionar`, `verificar` o `copiar` escriban en el pendrive, ejecuten
  algo de él o sigan un enlace fuera de él.
- Un manifiesto alterado que `verificar` da por bueno.
- Que `salida preparar` borre un disco que no es extraíble.

Lo que el README lista en «Qué no hace» no es una vulnerabilidad, aunque las ideas para cubrirlo son
bienvenidas como issue normal.

## Versiones con soporte

Solo la última versión publicada.
