#!/bin/bash
#--------------------------------------------------------
#Copyright (c) 2026 Oreste Colatruglio
#Este programa es software libre bajo licencia GNU GPLv3.
#--------------------------------------------------------

# COMPROBAMOS ROOT (EUID 0)
if [ "$EUID" -ne 0 ]; then
    # 1. Capturamos el usuario real antes de convertirnos en root
    USUARIO_ORIGINAL=$USER

    # 2. Volvemos a lanzar el script limpiando argumentos fantasmas (quitamos "$@")
    exec pkexec env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" REAL_USER="$USUARIO_ORIGINAL" "$0"
    exit 1
fi

# Exportamos para que todo el script y sus subprocesos los tengan disponibles
export DISPLAY
export XAUTHORITY
export REAL_USER
# Definimos el directorio actual de forma dinámica
DIR_ACTUAL=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export DIR_ACTUAL

# Variable global para controlar en qué pantalla estamos
PANTALLA_ACTUAL="mainMenu"
KEY=$(cat /usr/bin/kidc.blc 2>/dev/null) # Añadido 2>/dev/null por seguridad si no existe aún

# Detectamos qué terminal usar [Konsole para KDE(Abalinux12) o Mate(Abalinux11)]
if command -v konsole &> /dev/null; then
    TERM_CMD="konsole -e"
elif command -v mate-terminal &> /dev/null; then
    TERM_CMD="mate-terminal -e"
elif command -v gnome-terminal &> /dev/null; then
    TERM_CMD="gnome-terminal --"
else
    # Fallback básico: xterm (está en casi todos los Linux)
    TERM_CMD="xterm -e"
fi
export TERM_CMD

# =================================================================
# 🌟 OPTIMIZACIÓN: CACHÉ DE CONTROLADORES EN SEGUNDO PLANO
# =================================================================
# 1. Creamos un archivo temporal único e invisible en /tmp
CACHE_PPD=$(mktemp /tmp/canon_ppds_XXXXXX)

# 2. SEGURO DE BORRADO: Si el script se cierra o falla, Linux limpia el archivo
trap 'rm -f "$CACHE_PPD"' EXIT

# 3. Lanzamos el escaneo optimizado a la caché en segundo plano (&)
# Filtramos drivers inútiles (como "gutenprint" simplificados o "bjc" antiguos)
# que sobrecargan a Zenity y que ningún centro educativo usa hoy en día.
(
    /usr/sbin/lpinfo -m 2>/dev/null | grep -i "canon" | grep -vE "gutenprint|bjc|bj-" | awk '{print $1; $1=""; sub(/^ /, ""); print $0}' > "$CACHE_PPD"
) &
SCAN_PID=$! # Guardamos el ID del proceso

sleep 3
# =================================================================
# DETECCIÓN DE DISPOSITIVOS (proceso en segundo plano, no genera ventanas)
# -----------------------------------------------------------------
printDetect(){
    if ! command -v lpstat &> /dev/null; then
        zenity --error --text="CUPS no está instalado o lpstat no está disponible."
        return 1
    fi

    lista_dispositivos=($(lpstat -e))

    # Si no hay dispositivos instaladas, avisamos al usuario
    if [ ${#lista_dispositivos[@]} -eq 0 ]; then
        zenity --info --text="No se encontraron dispositivos instalados en el sistema."
        return 1
    fi

    # Construir los argumentos para la checklist de Zenity
    zenityArgs=()
    for dispositivo in "${lista_dispositivos[@]}"; do
        zenityArgs+=(FALSE "$dispositivo") # FALSE hace que aparezcan desmarcadas por defecto
    done
    return 0
}
# =================================================================

#Si no detecta los archivos intalados, ejecutar instalador de primera vez
if [[ ! -f "/usr/lib/cups/filter/canon_custom_id_filter" && ! -f "/usr/lib/cups/filter/canon_custom_id_filter_savemode" && ! -f "/var/tmp/.canonid/.Canon_DATAFILE.cbl" ]]; then
    PANTALLA_ACTUAL="setupMenu"
fi

#==================================================================
# 0.0 MENU SETUP PRIMERA VEZ
#-----------------------------------------------------------------

setupMenu(){
    zenity --question \
        --title="Administrador de dispositivos" \
        --width=250 \
        --text=" No se ha detectado una instalación anterior ¿Desea instalar un dispositivo?"
    setupMenuR=$?

    #Si el usuario selecciona "No"
    if [ $setupMenuR -eq 1 ]; then
        PANTALLA_ACTUAL="mainMenu"
    #Si el usuario selecciona "Si"
    else
        addFilter
        PANTALLA_ACTUAL="addPrinterMenu"
    fi
}
# 0.1 FILTROS NO INSTALADOS
filterMissingMenu(){
    zenity --question \
        --title="Administrador de dispositivos" \
        --width=250 \
        --text="No se han encontrado los filtros en los archivos del sistema\n ¿Desea instalar los filtros?"
    filterMissingMenuR=$?

    #Si el usuario selecciona "No"
    if [ $filterMissingMenuR -eq 1 ]; then
        PANTALLA_ACTUAL="mainMenu"
    #Si el usuario selecciona "Si"
    else
        addFilter
        PANTALLA_ACTUAL="mainMenu"
    fi
}

# 0.2 KEY NO GENERADA
keyMissingMenu(){
    zenity --question \
        --title="Administrador de dispositivos" \
        --width=250 \
        --text="No se ha encontrado la llave de encriptación en los archivos del sistema\n ¿Desea generar una llave nueva?"
    keyMissingMenuR=$?

    #Si el usuario selecciona "No"
    if [ $keyMissingMenuR -eq 1 ]; then
        PANTALLA_ACTUAL="mainMenu"
    #Si el usuario selecciona "Si"
    else
        keyGenerate
        PANTALLA_ACTUAL="mainMenu"
    fi
}

# =================================================================

# =================================================================
# 1. AÑADIR DISPOSITIVO (SIN IDs)
# -----------------------------------------------------------------
# 1.1 Pedir el nombre del dispositivo
addPrinterMenu(){
    while true; do
        printerName=$(zenity --entry \
                        --title="Añadir dispositivo" \
                        --width=350 \
                        --ok-label="Aceptar" \
                        --cancel-label="Atrás" \
                        --text="Indique el nombre del dispositivo (Puede contener cualquier carácter imprimible excepto /, # y espacios):")
        addPrinterMenuR=$?

        case $addPrinterMenuR in
            1) #Si se presiona Atrás:
                PANTALLA_ACTUAL="mainMenu"
                return
            ;;
            0) #Si se presiona Aceptar:
                # 1. Comprobamos si el campo está completamente vacío
                if [ -z "$printerName" ]; then
                    zenity --warning --title="Campo vacío" --text="El nombre del dispositivo no puede estar vacío." --width=250
                    continue # Vuelve a lanzar el menú

                # 2. COMPROBACIÓN DE CARACTERES INVÁLIDOS
                # Comprobamos si la variable contiene "/", "#" o un espacio en blanco " "
                elif [[ "$printerName" == *"/"* || "$printerName" == *"#"* || "$printerName" == *" "* ]]; then
                    # Si encuentra alguno de los caracteres prohibidos, lanza la advertencia
                    zenity --warning \
                        --title="Nombre no válido" \
                        --text="El nombre introducido contiene caracteres no permitidos (espacios, / o #).\n\nPor favor, introduzca un nombre válido sin estos caracteres." \
                        --width=350

                    continue # Vuelve al principio del 'while' para pedir el nombre de nuevo
                fi
                                # 3. Enviamos a la pantalla de IP
                PANTALLA_ACTUAL="IPMenu"
                return
            ;;
        esac

        # 4. ÉXITO: SALIMOS DEL BUCLE
        # Si el código llega hasta aquí, significa que pasó todas las pruebas.
        # Rompemos el bucle infinito.
    done
}
# 1.2 Pedir la IP del dispositivo
IPMenu(){
        IP=$(zenity --entry \
                    --title="Añadir dispositivo" \
                    --width=350 \
                    --ok-label="Aceptar" \
                    --cancel-label="Atrás" \
                    --text="Indique la dirección IP del dispositivo:")
        addIPMenuR=$?

        case $addIPMenuR in
            1) #Si se presiona Atrás:
                PANTALLA_ACTUAL="addPrinterMenu"
            ;;
            0) #Si se presiona Aceptar:
                #Enviamos a la pantalla de driver (ppdMenu)
                PANTALLA_ACTUAL="ppdMenu"
            ;;
        esac
}
# 1.3 Pedir el controlador PPD
ppdMenu(){
    # Si el proceso en segundo plano sigue trabajando, mostramos una espera elegante
    if kill -0 "$SCAN_PID" 2>/dev/null; then
        (
            while kill -0 "$SCAN_PID" 2>/dev/null; do
                sleep 0.3
            done
        ) | zenity --progress \
                   --title="Cargando controladores" \
                   --text="Generando lista rápida de controladores Canon...\nPor favor, espere un momento." \
                   --pulsate \
                   --auto-close \
                   --no-cancel \
                   --width=400
    fi

    # Cargamos la información instantáneamente desde nuestra caché reducida
    LISTA_MODELOS=$(cat "$CACHE_PPD")

    if [ -z "$LISTA_MODELOS" ]; then
        zenity --error --text="No se encontraron controladores Canon compatibles en el sistema."
        PANTALLA_ACTUAL="mainMenu"
        return
    fi

    # Zenity ahora abrirá de golpe porque el volumen de datos es mucho menor y óptimo
    PPD_SELECCIONADO=$(echo "$LISTA_MODELOS" | zenity --list \
        --title="Instalación" \
        --column="PPD" --column="Modelo" --hide-column=1 --print-column=1 \
        --width=600 --height=400 \
        --cancel-label="Atrás")

    if [ -n "$PPD_SELECCIONADO" ]; then
        # CORRECCIÓN DE SEGURIDAD: Escapamos bien las comillas internas para Konsole
        $TERM_CMD bash -c "su - -c 'lpadmin -p \"$printerName\" -v \"socket://$IP\" -m \"$PPD_SELECCIONADO\" && cupsaccept \"$printerName\" && cupsenable \"$printerName\" && sleep 2'"

        zenity --question \
        --title="Instalación de dispositivo" \
        --width=250 \
        --text="Dispositivo instalado con éxito ¿Desea configurar IDs?"
        ans=$?

        if [ $ans -eq 1 ]; then
            PANTALLA_ACTUAL="mainMenu"
        else
            PANTALLA_ACTUAL="configIDMenu"
        fi
    else
        PANTALLA_ACTUAL="IPMenu"
        return
    fi
}
# =================================================================


# =================================================================
# 2. ELIMINAR DISPOSITIVOS (SIN IDs)
# -----------------------------------------------------------------
rmPrinterMenu(){
    while true; do
        # Ejecutamos la detección. Si no hay dispositivos, salimos.
        printDetect
        if [ $? -ne 0 ]; then
            PANTALLA_ACTUAL="mainMenu"
            return
        fi

        rmPrinterMenuV=$(zenity --list \
                        --title="Eliminar dispositivos" \
                        --height=300 \
                        --width=500 \
                        --ok-label="Eliminar" \
                        --cancel-label="Atrás" \
                        --text="Seleccione lo/s dispositivo/s que desea eliminar del sistema:" \
                        --checklist \
                        --column=" " \
                        --column="Dispositivos" \
                        "${zenityArgs[@]}")

        rmPrinterMenuR=$?

        # 1. Si el usuario pulsa "Atrás" o cierra la ventana, salimos de la función
        if [ $rmPrinterMenuR -ne 0 ]; then
            PANTALLA_ACTUAL="mainMenu"
            return
        fi

        # 2. Si pulsó "Eliminar" pero no marcó ninguna casilla, avisamos y reiniciamos el menú
        if [ -z "$rmPrinterMenuV" ]; then
            zenity --warning --text="No ha seleccionado ningún dispositivo para eliminar." --width=300
            continue
        fi

        # 3. PROCESO DE ELIMINACIÓN MULTIPLE
        # Zenity devuelve las selecciones separadas por "|". Convertimos esa cadena en un array de Bash.
        IFS='|' read -ra IMPRESORAS_A_BORRAR <<< "$rmPrinterMenuV"

        # Recorremos el array y eliminamos una a una cada dispositivo seleccionada
        for dispositivo in "${IMPRESORAS_A_BORRAR[@]}"; do
            # xargs elimina espacios en blanco accidentales que puedan corromper el nombre
            dispositivo_limpio=$(echo "$dispositivo" | xargs)

            # Eliminamos de CUPS con privilegios de administrador
            $TERM_CMD bash -c "su - -c 'lpadmin -x "$dispositivo_limpio"'"
        done

        # 4. Avisamos del éxito de la operación
        zenity --info --text="Los dispositivos seleccionados han sido eliminados correctamente." --width=350


        # El bucle continúa de forma automática: volverá arriba, ejecutará 'printDetect'
        # y mostrará la lista actualizada sin las dispositivos que acabas de borrar.
    done
}
# =================================================================


# =================================================================
# 3. MENU DE CONFIGURACIÓN DE IDS
# -----------------------------------------------------------------
configIDMenu(){
    configIDMenuV=$(zenity --list \
                    --title="Configuración de IDs" \
                    --height=300 \
                    --width=500 \
                    --ok-label="Aceptar" \
                    --cancel-label="Atrás" \
                    --text="Selecciona una opción:" \
                    --hide-column=1 \
                    --print-column=2 \
                    --column="" \
                    --column="Opciones" \
                    TRUE "Añadir/modificar configuración de IDs"\
                    FALSE "Eliminar configuración de IDs")

    configIDMenuR=$?

    case $configIDMenuR in
        1) #Si se presiona Atrás:
            PANTALLA_ACTUAL="mainMenu"
        ;;
        0) #Si se presiona Aceptar:
            case $configIDMenuV in
                "Añadir/modificar configuración de IDs")
                    PANTALLA_ACTUAL="modeIDMenu"
                    ;;
                "Eliminar configuración de IDs")
                    PANTALLA_ACTUAL="rmIDPrinterMenu"
                    ;;
            esac
        ;;
    esac
}
# 3.1 Añadir IDs (elegir modo de IDs)
modeIDMenu(){
    modeIDMenuV=$(zenity --list \
                    --title="Modo de IDs" \
                    --height=300 \
                    --width=500 \
                    --ok-label="Aceptar" \
                    --cancel-label="Atrás" \
                    --text="Seleccione un modo de IDs:" \
                    --hide-column=1 \
                    --print-column=2 \
                    --column="" \
                    --column="Opciones" \
                    TRUE "Solicitar ID tras cada impresión" \
                    FALSE "Solicitar ID solo tras la primera impresión")

    modeIDMenuR=$?
    case $modeIDMenuR in
        1) #Si se presiona Atrás:
            PANTALLA_ACTUAL="configIDMenu"
        ;;
        0) #Si se presiona Aceptar:
            # 3. Enviamos a la pantalla de añadir IDs
            PANTALLA_ACTUAL="addIDPrinterMenu"
        ;;
    esac
}
# 3.1.1 Seleccionar dispositivos a los que se añadirán IDs
addIDPrinterMenu(){
    while true; do
        # Ejecutamos la detección. Si no hay dispositivos, salimos.
        printDetect
        if [ $? -ne 0 ]; then
            PANTALLA_ACTUAL="mainMenu"
            return
        fi

        addIDPrinterMenuV=$(zenity --list \
                        --title="Añadir configuración de IDs" \
                        --height=300 \
                        --width=500 \
                        --ok-label="Aceptar" \
                        --cancel-label="Atrás" \
                        --text="Seleccione lo/s dispositivo/s a las que desea implementar IDs" \
                        --checklist \
                        --column=" " \
                        --column="Dispositivos" \
                        "${zenityArgs[@]}")

        addIDPrinterMenuR=$?

        case $addIDPrinterMenuR in
            1) #Si se presiona Atrás:
                PANTALLA_ACTUAL="modeIDMenu"
                return
            ;;
            0) #Si se presiona Aceptar:Z
                # Si dio a aceptar pero no marcó ninguna casilla, volvemos al menú
                if [ -z "$addIDPrinterMenuV" ]; then
                    zenity --warning --text="No seleccionaste ningún dispositivo."
                    continue
                fi
                if [[ "$modeIDMenuV" == "Solicitar ID tras cada impresión" ]]; then
                    # 1. Creamos el script de modificación en /tmp de forma aislada
                    cat << 'EOF' > /tmp/modificar_ppds.sh
#!/bin/bash
SELECCION="$1"

# Convertimos la lista "Imp1|Imp2" en un array de Bash
IFS="|" read -r -a imps <<< "$SELECCION"

echo -e "=== INICIANDO REEMPLAZO DE FILTRO EN ARCHIVOS PPD ===\n"

for imp in "${imps[@]}"; do
    # SOLUCIÓN: Buscamos el archivo ignorando mayúsculas/minúsculas (-iname)
    archivo_ppd=$(find /etc/cups/ppd/ -maxdepth 1 -iname "${imp}.ppd" -print -quit)

    if [ -n "$archivo_ppd" ] && [ -f "$archivo_ppd" ]; then
        # Buscamos 'foomatic-rip' y lo cambiamos por tu filtro personalizado
        sed -i 's/canon_custom_id_filter_savemode/canon_custom_id_filter/g' "$archivo_ppd"
        sed -i 's/foomatic-rip/canon_custom_id_filter/g' "$archivo_ppd"
        echo "[OK] Filtro personalizado aplicado a: $(basename "$archivo_ppd")"
    else
        echo "[ERROR] No se encontró el archivo PPD para: $imp (buscado como ${imp}.ppd)"
    fi
done

echo -e "\n=== REINICIANDO EL SERVICIO DE CUPS ==="
# Forzamos el reinicio para que CUPS lea las modificaciones en caliente
systemctl restart cups || service cups restart

echo -e "\n[PROCESO COMPLETADO EXIOTOSAMENTE]"
EOF

                # 2. Lo ejecutamos en Konsole solicitando permisos de root una sola vez
                $TERM_CMD bash -c "su -c 'bash /tmp/modificar_ppds.sh \"$addIDPrinterMenuV\" && rm -f /tmp/modificar_ppds.sh && sleep 3'"
                PANTALLA_ACTUAL="configIDMenu"
                return
                elif [[ "$modeIDMenuV" == "Solicitar ID solo tras la primera impresión" ]]; then
                    # 1. Creamos el script de modificación en /tmp de forma aislada
                    cat << 'EOF' > /tmp/modificar_ppds.sh
#!/bin/bash
SELECCION="$1"

# Convertimos la lista "Imp1|Imp2" en un array de Bash
IFS="|" read -r -a imps <<< "$SELECCION"

echo -e "=== INICIANDO REEMPLAZO DE FILTRO EN ARCHIVOS PPD ===\n"

for imp in "${imps[@]}"; do
    # SOLUCIÓN: Buscamos el archivo ignorando mayúsculas/minúsculas (-iname)
    archivo_ppd=$(find /etc/cups/ppd/ -maxdepth 1 -iname "${imp}.ppd" -print -quit)

    if [ -n "$archivo_ppd" ] && [ -f "$archivo_ppd" ]; then
        # Buscamos 'foomatic-rip' y lo cambiamos por tu filtro personalizado
        sed -i 's/canon_custom_id_filter/canon_custom_id_filter_savemode/g' "$archivo_ppd"
        sed -i 's/foomatic-rip/canon_custom_id_filter_savemode/g' "$archivo_ppd"
        echo "[OK] Filtro personalizado aplicado a: $(basename "$archivo_ppd")"
    else
        echo "[ERROR] No se encontró el archivo PPD para: $imp (buscado como ${imp}.ppd)"
    fi
done

echo -e "\n=== REINICIANDO EL SERVICIO DE CUPS ==="
# Forzamos el reinicio para que CUPS lea las modificaciones en caliente
systemctl restart cups || service cups restart

echo -e "\n[PROCESO COMPLETADO EXIOTOSAMENTE]"
EOF

                # 2. Lo ejecutamos en Konsole solicitando permisos de root una sola vez
                $TERM_CMD bash -c "su -c 'bash /tmp/modificar_ppds.sh \"$addIDPrinterMenuV\" && rm -f /tmp/modificar_ppds.sh && sleep 3'"
                PANTALLA_ACTUAL="configIDMenu"
                return
                fi
                ;;
        esac
    done
}
# 3.2 Deshacer configuración de IDs
rmIDPrinterMenu(){
    while true; do
        # Ejecutamos la detección. Si no hay dispositivos, salimos.
        printDetect
        if [ $? -ne 0 ]; then
            PANTALLA_ACTUAL="mainMenu"
            return
        fi

        rmIDPrinterMenuV=$(zenity --list \
                        --title="Añadir configuración de IDs" \
                        --height=300 \
                        --width=500 \
                        --ok-label="Aceptar" \
                        --cancel-label="Atrás" \
                        --text="Seleccione lo/s dispositivo/s a las que desea quitar IDs" \
                        --checklist \
                        --column=" " \
                        --column="Dispositivos" \
                        "${zenityArgs[@]}")

        rmIDPrinterMenuR=$?

        # CASO 1: El usuario pulsa Aceptar
        if [ $rmIDPrinterMenuR -eq 0 ]; then
            # Si dio a aceptar pero no marcó ninguna casilla, volvemos al menú
            if [ -z "$rmIDPrinterMenuV" ]; then
                zenity --warning --text="No seleccionaste ningún dispositivo."
                return
            fi

            # 1. Creamos el script de modificación en /tmp de forma aislada
            cat << 'EOF' > /tmp/modificar_ppds.sh
#!/bin/bash
SELECCION="$1"

# Convertimos la lista "Imp1|Imp2" en un array de Bash
IFS="|" read -r -a imps <<< "$SELECCION"

echo -e "=== INICIANDO ELIMINACION DE FILTRO EN ARCHIVOS PPD ===\n"

for imp in "${imps[@]}"; do
    # SOLUCIÓN: Buscamos el archivo ignorando mayúsculas/minúsculas (-iname)
    archivo_ppd=$(find /etc/cups/ppd/ -maxdepth 1 -iname "${imp}.ppd" -print -quit)

    if [ -n "$archivo_ppd" ] && [ -f "$archivo_ppd" ]; then
        # Buscamos 'canon_custom_id_filter' y lo cambiamos por el filtro por defecto
        sed -i 's/foomatic_rip_savemode/foomatic-rip/g' "$archivo_ppd"
        sed -i 's/canon_custom_id_filter_savemode/foomatic-rip/g' "$archivo_ppd"
        sed -i 's/canon_custom_id_filter/foomatic-rip/g' "$archivo_ppd"
        echo "[OK] Filtro personalizado aplicado a: $(basename "$archivo_ppd")"
    else
        echo "[ERROR] No se encontró el archivo PPD para: $imp (buscado como ${imp}.ppd)"
    fi
done

echo -e "\n=== REINICIANDO EL SERVICIO DE CUPS ==="
# Forzamos el reinicio para que CUPS lea las modificaciones en caliente
systemctl restart cups || service cups restart

echo -e "\n[PROCESO COMPLETADO EXIOTOSAMENTE]"
EOF

            # 2. Lo ejecutamos en Konsole solicitando permisos de root una sola vez
            $TERM_CMD bash -c "su -c 'bash /tmp/modificar_ppds.sh \"$rmIDPrinterMenuV\" && rm -f /tmp/modificar_ppds.sh && sleep 3'"
            PANTALLA_ACTUAL="configIDMenu"
            return
        fi

        # CASO 2: El usuario pulsa Atrás
        if [ $rmIDPrinterMenuR -eq 1 ]; then
            PANTALLA_ACTUAL="mainMenu"
            return
        fi
    done
}
# =================================================================


# =================================================================
# 4. GESTIONAR Utilidades
# -----------------------------------------------------------------
utilMenu(){
    utilMenuV=$(zenity --list \
                    --title="Utilidades" \
                    --height=350 \
                    --width=500 \
                    --ok-label="Aceptar" \
                    --cancel-label="Atrás" \
                    --text="Selecciona una opción:" \
                    --hide-column=1 \
                    --print-column=2 \
                    --column="" \
                    --column="Opciones" \
                    TRUE "Instalar filtros personalizados de IDs" \
                    FALSE "Eliminar filtros personalizados de IDs" \
                    FALSE "Generar nueva llave de cifrado" \
                    FALSE "Borrar base de datos de IDs"\
                    FALSE "¡Borrar TODO!"\
                    FALSE "Abrir CUPS"\
                    FALSE "Reiniciar CUPS"\
                    FALSE "Abrir Github"\
                    FALSE "Descargar drivers")

    utilMenuR=$?


    case $utilMenuR in
        1) #Si se presiona Atrás:
            PANTALLA_ACTUAL="mainMenu"
            return
        ;;
        0) #Si se presiona Aceptar:
            case $utilMenuV in
                "Instalar filtros personalizados de IDs")
                    addFilter
                ;;
                "Eliminar filtros personalizados de IDs")
                    # Pasamos la variable a una local segura para que bash -c no la pierda
                    rmFilter
                ;;
                "Generar nueva llave de cifrado")
                    keyGenerate
                ;;
                "Borrar base de datos de IDs")
                    PANTALLA_ACTUAL="rmIdDatabase"
                ;;
                "¡Borrar TODO!")
                    PANTALLA_ACTUAL="rmAll"
                ;;
                "Abrir CUPS")
                    # Usamos Python para esquivar el bug de xdg-open y KDE.
                    # nohup y >/dev/null 2>&1 & lo desvinculan por completo para no congelar Zenity.
                    su "$REAL_USER" -c "env DISPLAY=\"$DISPLAY\" XAUTHORITY=\"$XAUTHORITY\" nohup python3 -m webbrowser 'http://localhost:631' >/dev/null 2>&1 &"
                ;;
                "Reiniciar CUPS")
                    $TERM_CMD bash -c "
                        systemctl restart cups
                        echo -e '\n[OK] Servicio de impresión reiniciado. Cerrando...'
                        sleep 1
                    "
                ;;
                "Abrir Github")
                    # Usamos Python para esquivar el bug de xdg-open y KDE.
                    # nohup y >/dev/null 2>&1 & lo desvinculan por completo para no congelar Zenity.
                    su "$REAL_USER" -c "env DISPLAY=\"$DISPLAY\" XAUTHORITY=\"$XAUTHORITY\" nohup python3 -m webbrowser 'https://github.com/forestcolat/SGID' >/dev/null 2>&1 &"
                ;;
                "Descargar drivers")
                    # Usamos Python para esquivar el bug de xdg-open y KDE.
                    # nohup y >/dev/null 2>&1 & lo desvinculan por completo para no congelar Zenity.
                    su "$REAL_USER" -c "env DISPLAY=\"$DISPLAY\" XAUTHORITY=\"$XAUTHORITY\" nohup python3 -m webbrowser 'https://www.canon.es/support/business/' >/dev/null 2>&1 &"
                ;;
            esac
        ;;
    esac
}

# 4.1 NZ- Instalar filtros personalizados de intalados
addFilter(){
    $TERM_CMD bash -c "
        echo '=== INICIANDO INSTALACIÓN DE FILTROS ==='

        echo -e '\n[1/4] Copiando y configurando filtro principal...'
        cp \"$DIR_ACTUAL/canon_custom_id_filter\" /usr/lib/cups/filter/canon_custom_id_filter
        chown root:root /usr/lib/cups/filter/canon_custom_id_filter
        chmod 755 /usr/lib/cups/filter/canon_custom_id_filter
        echo '[OK] Filtro principal instalado con permisos correctos.'

        echo -e '\n[2/4] Copiando y configurando filtro de guardado...'
        cp \"$DIR_ACTUAL/canon_custom_id_filter_savemode\" /usr/lib/cups/filter/canon_custom_id_filter_savemode
        chown root:root /usr/lib/cups/filter/canon_custom_id_filter_savemode
        chmod 755 /usr/lib/cups/filter/canon_custom_id_filter_savemode
        echo '[OK] Filtro de guardado instalado con permisos correctos.'

        REGLA='lp ALL=(ALL) NOPASSWD: /usr/bin/zenity'
        ARCHIVO_SUDOERS='/etc/sudoers'

        echo 'Verificando permisos de sudo para el usuario lp...'

        # Escapamos el \$ y usamos comillas dobles para que el bash INTERNO resuelva las variables
        if grep -qF \"\$REGLA\" \"\$ARCHIVO_SUDOERS\"; then
            echo ' -> El permiso para Zenity ya está configurado. Omitiendo.'
        else
            echo ' -> Permiso no encontrado. Añadiendo regla a sudoers...'
            
            # Añadimos la regla
            echo \"\$REGLA\" >> \"\$ARCHIVO_SUDOERS\"
            
            # Validación
            if visudo -cf \"\$ARCHIVO_SUDOERS\" > /dev/null 2>&1; then
                echo ' -> Permiso añadido y validado correctamente.'
            else
                echo ' -> ¡ATENCIÓN! Se detectó un error de sintaxis en sudoers tras la modificación.'
            fi
        fi

        echo -e '\n[3/4] Creando base de datos de IDs y clave de cifrado...'
        mkdir -p \"/var/tmp/.canonid\"
        chmod 777 \"/var/tmp/.canonid\"
        
        if [ ! -f \"/usr/bin/kidc.blc\" ]; then
            openssl rand -base64 32 > \"/usr/bin/kidc.blc\"
        fi
        
        chown root:lp \"/usr/bin/kidc.blc\"
        chmod 640 \"/usr/bin/kidc.blc\"

        touch \"/var/tmp/.canonid/.Canon_DATAFILE.cbl\"

        # Aquí pasa lo mismo que con DIR_ACTUAL: \$KEY viene de fuera, así que no escapamos su dólar
        echo '' | openssl enc -aes-256-cbc -a -pbkdf2 -pass pass:\"$KEY\" -out /var/tmp/.canonid/.Canon_DATAFILE.cbl

        chown lp:lp \"/var/tmp/.canonid/.Canon_DATAFILE.cbl\"
        chmod 640 \"/var/tmp/.canonid/.Canon_DATAFILE.cbl\"
        
        # Corregido un pequeño typo de tu script: la ruta real es /var/tmp, no /usr/lib/cups
        echo '[OK] Base de datos y clave de cifrado configuradas en /var/tmp/.canonid'

        echo -e '\n[4/4] Reiniciando el servicio de impresión (CUPS)...'
        systemctl restart cups
        echo '[OK] Servicio de impresión reiniciado con éxito.'

        echo -e '\n=== ¡PROCESO COMPLETADO CON ÉXITO! ==='
        echo 'Esta ventana se cerrará automáticamente en 3 segundos...'
        sleep 3
    "
}
# 4.2 NZ- Eliminar filtros personalizados de intalados
rmFilter(){
    $TERM_CMD bash -c "
        echo '=== INICIANDO ELIMINACION DE FILTROS ==='

        echo -e '\n[1/2] Eliminando filtro principal...'
        rm -f /usr/lib/cups/filter/canon_custom_id_filter
        echo '[OK] Filtro principal eliminado correctamente.'

        echo -e '\n[2/2] Eliminando filtro de guardado...'
        rm -f /usr/lib/cups/filter/canon_custom_id_filter_savemode
        echo '[OK] Filtro de guardado eliminado correctamente.'

        echo -e \"\n\n[OK] Filtros eliminados correctamente del sistema.\"
        systemctl restart cups
        echo -e \"\n[OK] Servicio de impresión reiniciado. Cerrando...\"

        echo -e '\n=== ¡PROCESO COMPLETADO CON ÉXITO! ==='
        echo 'Esta ventana se cerrará automáticamente en 3 segundos...'
        sleep 3
    "
}
# 4.4 Borrar base de datos de ID (reescribir el archivo y dejarlo en blanco, pero conservarlo)
rmIdDatabase(){
    while true; do
        zenity --question \
            --title="Borrar base de datos de IDs" \
            --width=350 \
            --text="Esta acción vaciará todos los IDs almacenados en la base de datos del sistema. ¿Quieres continuar?"
        ans=$?

        if [ $ans -eq 0 ]; then
            $TERM_CMD bash -c "
                echo 'Vaciando base de datos...'
                # 1. Recuperamos la contraseña del sistema
                KEY=$(cat /usr/bin/kidc.blc)

                # 2. Ciframos un contenido vacío hacia la base de datos
                echo '' | openssl enc -aes-256-cbc -a -pbkdf2 -pass pass:"$KEY" -out /var/tmp/.canonid/.Canon_DATAFILE.cbl

                # 3. Nos aseguramos de que el usuario de impresión siga siendo el dueño
                chown lp:lp /var/tmp/.canonid/.Canon_DATAFILE.cbl
                chmod 660 /var/tmp/.canonid/.Canon_DATAFILE.cbl
                echo -e '\n[OK] Base de datos eliminada correctamente del sistema.'
                echo 'Esta ventana se cerrará automáticamente en 2 segundos...'
                sleep 2
            "

            # 🌟 CORRECCIÓN CRÍTICA: Decimos a dónde ir y rompemos el bucle while
            PANTALLA_ACTUAL="utilMenu"
            return

        elif [ $ans -eq 1 ]; then
            # Si dice que no o cierra la ventana, volvemos limpiamente atrás
            PANTALLA_ACTUAL="utilMenu"
            return
        fi
    done
}
# # 4.5 Borrar TODO
rmAll(){
    while true; do
        zenity --question \
            --title="¡Borrar TODO!" \
            --width=350 \
            --text="Esta acción borrará todos los archivos creados en el sistema, incluyendo filtros, base de datos y llave de seguridad.\n Tenga en cuenta que el borrado no corrige los dispositivos modificados ¿Desea continuar?"
        ans=$?

        if [ $ans -eq 0 ]; then
            $TERM_CMD bash -c "
                rm -f /usr/bin/kidc.blc /var/tmp/.canonid/.Canon_DATAFILE.cbl /usr/lib/cups/filter/canon_custom_id_filter /usr/lib/cups/filter/canon_custom_id_filter_savemode
                echo -e '\n[OK] Se han eliminado todos los archivos del sistema\n ¡RECUERDE ELIMINAR LAS IMPRESORAS MODIFICADAS!'
                echo 'Esta ventana se cerrará automáticamente en 2 segundos...'
                sleep 2
            "

            # 🌟 CORRECCIÓN CRÍTICA: Decimos a dónde ir y rompemos el bucle while
            PANTALLA_ACTUAL="utilMenu"
            return

        elif [ $ans -eq 1 ]; then
            # Si dice que no o cierra la ventana, volvemos limpiamente atrás
            PANTALLA_ACTUAL="utilMenu"
            return
        fi
    done
}
# 4.6 Información útil para el técnico
infoMenu(){
    zenity --info \
        --title="Información adicional" \
        --width=350 \
        --text="
            ruta de filtros personalizados: /usr/lib/cups/filter/\n
            ruta de base de datos: /var/tmp/.canonid/.Canon_DATAFILE.cbl\n
            ruta de llave secreta: /usr/bin/kidc.blc\n
            Licencia: Copyright (c) 2026 Oreste Colatruglio\nEste programa es software libre bajo licencia GNU GPLv3.
            "
    ans=$?
    PANTALLA_ACTUAL="mainMenu"
}
#=================================================================

# =================================================================
# ROTACIÓN DE LLAVES (Descifra, genera nueva llave, y re-cifra)
# =================================================================
keyGenerate(){
    zenity --question \
        --title="Generar nueva llave de cifrado" \
        --width=400 \
        --text="Esta acción descifrará la base de datos actual, generará una nueva llave de seguridad y volverá a cifrar los datos con ella.\n¿Desea continuar?"
    keyGenerateR=$?

    if [ $keyGenerateR -eq 0 ]; then
        $TERM_CMD bash -c '
            echo "=== INICIANDO ROTACIÓN DE LLAVES ==="

            ARCHIVO_DB="/var/tmp/.canonid/.Canon_DATAFILE.cbl"
            ARCHIVO_LLAVE="/usr/bin/kidc.blc"

            # 1. Comprobamos si existen archivos previos para descifrar
            if [ -f "$ARCHIVO_LLAVE" ] && [ -f "$ARCHIVO_DB" ]; then
                echo "[1/4] Leyendo llave antigua y descifrando base de datos..."
                LLAVE_ANTIGUA=$(cat "$ARCHIVO_LLAVE")

                # Extraemos los datos a una variable temporal en la RAM
                DATOS_DESCIFRADOS=$(openssl enc -aes-256-cbc -d -a -pbkdf2 -pass pass:"$LLAVE_ANTIGUA" -in "$ARCHIVO_DB" 2>/dev/null)

                # Verificamos si el descifrado fue exitoso (evita borrar datos si la llave vieja estaba corrupta)
                if [ $? -ne 0 ]; then
                    echo "[ERROR FATAL] No se pudo descifrar la base de datos. Operación abortada por seguridad."
                    sleep 4
                    exit 1
                fi
            else
                echo "[1/4] No se encontró base de datos previa. Se inicializará una limpia."
                DATOS_DESCIFRADOS=""
            fi

            echo "[2/4] Generando nueva llave criptográfica..."
            NUEVA_LLAVE=$(openssl rand -base64 32)

            echo "[3/4] Cifrando los datos con la nueva llave..."
            echo "$DATOS_DESCIFRADOS" | openssl enc -aes-256-cbc -a -pbkdf2 -pass pass:"$NUEVA_LLAVE" -out "$ARCHIVO_DB"

            echo "[4/4] Guardando la nueva llave en el sistema..."
            echo "$NUEVA_LLAVE" > "$ARCHIVO_LLAVE"

            # Restauramos permisos de seguridad blindados
            chown root:lp "$ARCHIVO_LLAVE"
            chmod 640 "$ARCHIVO_LLAVE"
            chown lp:lp "$ARCHIVO_DB"
            chmod 660 "$ARCHIVO_DB"

            echo -e "\n[OK] ¡Llave rotada y base de datos actualizada con éxito!"
            echo "Esta ventana se cerrará automáticamente en 3 segundos..."
            sleep 3
        '

        # Actualizamos la variable global del script por si se usa más adelante
        KEY=$(cat /usr/bin/kidc.blc 2>/dev/null)

        # Volvemos al menú de utilidades
        PANTALLA_ACTUAL="utilMenu"
        return

    elif [ $keyGenerateR -eq 1 ]; then
        PANTALLA_ACTUAL="utilMenu"
        return
    fi
}

# =================================================================
# CONTROLADOR CENTRAL (Reemplaza a tu viejo mainMenu)
# =================================================================
controladorPrincipal(){
    while true; do
        case $PANTALLA_ACTUAL in
            "mainMenu")
                # Aquí lanzas tu Zenity del menú de inicio
                mainMenuV=$(zenity  --list \
                                    --title="SGID v1.0" \
                                    --height=300 \
                                    --width=500 \
                                    --ok-label="Aceptar" \
                                    --cancel-label="Salir" \
                                    --text="Selecciona una opción:" \
                                    --hide-column=1 \
                                    --print-column=2 \
                                    --column="" \
                                    --column="Opciones" \
                                    TRUE "Añadir dispositivo"\
                                    FALSE "Eliminar dispositivo"\
                                    FALSE "Configuración de IDs" \
                                    FALSE "Utilidades" \
                                    FALSE "Información adicional")

                        mainMenuR=$?

                        case $mainMenuR in
                            1) #Si se presiona Atrás:
                                exit 0
                                break
                            ;;
                            0) #Si se presiona Aceptar:
                                case $mainMenuV in
                                    "Añadir dispositivo")
                                        PANTALLA_ACTUAL="addPrinterMenu"
                                    ;;
                                    "Eliminar dispositivo")
                                        PANTALLA_ACTUAL="rmPrinterMenu"
                                    ;;
                                    "Configuración de IDs")
                                        PANTALLA_ACTUAL="configIDMenu"
                                    ;;
                                    "Utilidades")
                                        PANTALLA_ACTUAL="utilMenu"
                                    ;;
                                    "Información adicional")
                                        PANTALLA_ACTUAL="infoMenu"
                                    ;;
                                esac
                            ;;
                        esac
            ;;
            "addPrinterMenu")
                addPrinterMenu
            ;;
            "IPMenu")
                IPMenu
            ;;
            "ppdMenu")
                ppdMenu
            ;;
            "rmPrinterMenu")
                rmPrinterMenu
            ;;
            "configIDMenu")
                configIDMenu
            ;;
            "modeIDMenu")
                modeIDMenu
            ;;
            "addIDPrinterMenu")
                addIDPrinterMenu
            ;;
            "rmIDPrinterMenu")
                rmIDPrinterMenu
            ;;
            "utilMenu")
                utilMenu
            ;;
            "rmIdDatabase")
                rmIdDatabase
            ;;
            "rmAll")
                rmAll
            ;;
            "infoMenu")
                infoMenu
            ;;
            "setupMenu")
                setupMenu
            ;;
        esac
    done
}

# Iniciamos el script llamando únicamente al controlador
controladorPrincipal
