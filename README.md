# Script para la Gestión de IDs (SGID)
Un script diseñado para ser utilizado en ABalinux11 y Abalinux12 para instalar dispositivos de impresión y gestionar el uso de IDs de departamentos.

## Funcionamiento
El script trabaja a través de los filtros de información del servicio de impresión CUPS. Al imprimir, CUPS envía ciertos parámetros a uno de estos filtros (que es un script de bash) para convertir la información y transmitirla a un dispositivo. Si se imprimiese desde el navegador Chrome, la ruta sería:

Chrome→CUPS (parámetros de de archivo)→filtro→Máquina

Lo que hace este programa es instalar un filtro personalizado en el sistema operativo, reemplazando el filtro que un dispositivo en concreto utiliza. Este filtro personalizado intercepta la información de CUPS y la retiene mientras pregunta al usuario mediante una ventana generada por zenity el ID de departamento. Una vez ingresado el ID, el programa añade a la información original el parámetro de ID junto con el valor correspondiente. Esto permite la inserción de un ID dinámico que pueda alterarse en cada impresión y no esté sujeto a las restricciones tradicionales del sistema. Un esquema actualizado sería de la siguiente forma:

Chrome→CUPS→filtro personalizado→ventana de Zenity→parámetros + ID→filtro original→Máquina



## Instalación
> [!CAUTION]
> Si bien no se apreciaron problemas en la ejecución del software, no me hago responsable del uso indebido o daño que un usuario pueda ocasionar en su ordenador o dispositivo de impresión. El uso de este software está estrictamente recomendado a técnicos calificados para el mantenimiento de dispositivos multifunción.
1. Instalar los drivers `cque-es-4.0-15.x86_64.deb`. También se pueden [descargar](https://www.canon.es/support/) desde la páginsa de soporte oficial de canon (Driver CQue DEB)
2. Descargar el programa en la sección de [descargas](google.com)
3. Extraer el programa.
4. Click derecho en `config_IDs_Linux.sh` → propiedades → permisos → marcar casilla `Es ejecutable` → Aceptar
5. Doble click para ejectuar, o alternativamente, abrir una ventana de terminal y arrastar hacia ella.
6. Ingresar la contraseña de administrador.

El script detectará si faltan archivos y de ser así, abrirá una ventana sugiriendo al usuario una instalación guiada. 

## Funciones
### Añadir dispositivo
Permite al usuario añadir desde cero un dispositivo nuevo especificando su nombre, dirección IP y driver correspondiente. Tras finalizar el proceso, se genera una ventana preguntando al usuario si deseea configurar IDs de departamento.
### Eliminar dispositivo
Permite al usuario eliminar varios dispositivos a la vez.
### Configuración de IDs
Permite al usuario habilitar o deshabilitar el uso de IDs de departamento. La configuración permite que los dispositivos seleccionados puedan solicitar el ID tras cada impresión o solicitarlo una primera vez, almacenando el ID y asociándolo al usuario usado para imprimir.
### Utilidades
Una serie de opciones útiles para el usuario que pueden ayudar a solucionar problemas, como descargar drivers, reiniciar el servicio de impresión o deshacer todos los cambios hechos por el programa.
### Información adicional
Indica las rutas de los archivos utilizados por el programa, así como la declaración de licencia GNU.

> [!WARNING]
> Este programa fue probado con dispositivos Canon de la gama imageRUNNER ADVANCE, imageRUNNER ADVANCE DX e imageFORCE bajo condiciones controladas y supervisadas por personal calificado. No se puede asegurar el correcto funcionamiento en dispositivos en los que no ha sido testeado, por tanto, si se desea utilizar en un dispositivo de gama diferente a las mencionadas, se recomienda encarecidamente probar bajo condiciones controladas en un entorno que no pueda afectar el flujo del trabajo del cliente.
>
> De la misma forma, es posible la utilización de este programa en dispositivos de marcas diferentes a Canon, no obstante, desconozco los resulados que esto pueda generar en los dispositivos así como las adapciones que deban realizarse para hacer el programa compatible con otras marcas de dispositivos.
