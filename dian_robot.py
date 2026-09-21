#!/usr/bin/env python3
"""
Robot DIAN - corrige el redondeo de los XML y recalcula el CUFE.

Dos formas de usarlo (ver LEEME.txt):

  1) Arrastrar uno o varios XML sobre  1_CORREGIR_ARRASTRANDO.bat
  2) Dejar el .bat  2_VIGILAR_CARPETA.bat  abierto: todo XML que caiga en
     la carpeta "entrada" se corrige solo y aparece en "salida".

Tambien por consola:
    python dian_robot.py factura.xml
    python dian_robot.py C:\\ruta\\carpeta_con_xmls
    python dian_robot.py --vigilar
"""

import configparser
import csv
import os
import shutil
import sys
import time
from datetime import datetime

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)

import dian_check  # noqa: E402

CONFIG_PATH = os.path.join(BASE, "config.ini")
LOG_PATH = os.path.join(BASE, "registro.csv")


# ---------------------------------------------------------------- config


def leer_config():
    parser = configparser.ConfigParser()
    if not os.path.exists(CONFIG_PATH):
        raise SystemExit(f"No encuentro config.ini en {BASE}")
    parser.read(CONFIG_PATH, encoding="utf-8")
    dian = parser["dian"]
    carpetas = parser["carpetas"]

    clave = dian.get("clave_tecnica", "").strip()
    ambiente = dian.get("ambiente", "").strip()

    if not clave or clave.upper().startswith("PEGA"):
        clave = None
    if ambiente not in ("1", "2"):
        ambiente = None

    def ruta(nombre, defecto):
        valor = carpetas.get(nombre, "").strip() or defecto
        if not os.path.isabs(valor):
            valor = os.path.join(BASE, valor)
        return valor

    return {
        "clave_tecnica": clave,
        "ambiente": ambiente,
        "entrada": ruta("entrada", "entrada"),
        "salida": ruta("salida", "salida"),
        "procesados": ruta("procesados", "procesados"),
        "errores": ruta("errores", "errores"),
        "intervalo": int(carpetas.get("intervalo_segundos", "5") or 5),
    }


# ---------------------------------------------------------------- registro


def anotar(fila):
    """Agrega una linea al registro.csv (se crea con encabezado si no existe)."""
    nuevo = not os.path.exists(LOG_PATH)
    with open(LOG_PATH, "a", newline="", encoding="utf-8-sig") as handle:
        writer = csv.writer(handle, delimiter=";")
        if nuevo:
            writer.writerow(["fecha", "archivo", "documento", "descuadres",
                             "venia_firmado", "cufe_anterior", "cufe_nuevo",
                             "resultado"])
        writer.writerow(fila)


# ---------------------------------------------------------------- proceso


def corregir(xml_path, config, carpeta_salida=None):
    """Corrige un XML. Devuelve (ok, mensaje_corto)."""
    nombre = os.path.basename(xml_path)
    raiz, _ = os.path.splitext(nombre)
    destino_dir = carpeta_salida or os.path.dirname(os.path.abspath(xml_path))
    os.makedirs(destino_dir, exist_ok=True)

    salida_xml = os.path.join(destino_dir, f"{raiz}_corregido.xml")
    salida_txt = os.path.join(destino_dir, f"{raiz}_informe.txt")
    sello = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    try:
        result = dian_check.procesar(xml_path, config["clave_tecnica"],
                                     config["ambiente"])
    except Exception as error:  # XML roto, no es UBL, etc.
        anotar([sello, nombre, "", "", "", "", "", f"ERROR: {error}"])
        return False, f"ERROR leyendo {nombre}: {error}"

    texto = dian_check.informe(result, nombre, config["clave_tecnica"])
    result["tree"].write(salida_xml, encoding="UTF-8", xml_declaration=True)
    with open(salida_txt, "w", encoding="utf-8") as handle:
        handle.write(texto + "\n")

    cantidad = len(result["issues"])
    anotar([sello, nombre, result["doc_type"], cantidad,
            "SI" if result["signed"] else "NO",
            result["cufe_anterior"] or "", result["cufe_nuevo"] or "",
            "CORREGIDO" if cantidad else "YA ESTABA BIEN"])

    resumen = (f"{nombre}: {cantidad} descuadre(s) corregido(s)"
               if cantidad else f"{nombre}: ya estaba bien")
    if result["signed"]:
        resumen += "  [venia FIRMADO - hay que volver a firmarlo]"
    if not result["cufe_nuevo"]:
        resumen += "  [sin clave tecnica en config.ini: CUFE NO recalculado]"
    return True, resumen


def xmls_en(ruta):
    if os.path.isdir(ruta):
        return sorted(os.path.join(ruta, n) for n in os.listdir(ruta)
                      if n.lower().endswith(".xml")
                      and not n.lower().endswith("_corregido.xml"))
    return [ruta]


# ---------------------------------------------------------------- modos


def modo_archivos(rutas, config):
    total = 0
    for ruta in rutas:
        for xml_path in xmls_en(ruta):
            ok, mensaje = corregir(xml_path, config)
            print(("  OK  " if ok else "  --  ") + mensaje)
            total += 1
    if total == 0:
        print("No recibi ningun XML.")
    else:
        print(f"\nListo. {total} archivo(s) procesado(s).")
        print("Revisa el _informe.txt de cada uno para ver que se cambio.")


def estable(ruta, intentos=3, espera=0.4):
    """Espera a que el archivo deje de crecer antes de leerlo.

    El ERP puede estar escribiendolo todavia cuando el robot lo ve aparecer.
    """
    ultimo = -1
    for _ in range(intentos * 10):
        try:
            actual = os.path.getsize(ruta)
        except OSError:
            return False
        if actual == ultimo and actual > 0:
            return True
        ultimo = actual
        time.sleep(espera)
    return False


def modo_vigilar(config):
    for carpeta in ("entrada", "salida", "procesados", "errores"):
        os.makedirs(config[carpeta], exist_ok=True)

    print("Robot DIAN vigilando.")
    print(f"  Deja los XML en : {config['entrada']}")
    print(f"  Salen corregidos: {config['salida']}")
    if not config["clave_tecnica"]:
        print("  AVISO: config.ini sin clave tecnica -> el CUFE no se recalcula.")
    print("\nDeja esta ventana abierta. Ctrl+C para parar.\n", flush=True)

    while True:
        try:
            pendientes = xmls_en(config["entrada"])
        except OSError:
            pendientes = []

        for xml_path in pendientes:
            if not estable(xml_path):
                continue
            ok, mensaje = corregir(xml_path, config, config["salida"])
            hora = datetime.now().strftime("%H:%M:%S")
            # flush: en modo vigilar la ventana queda abierta horas y hay que
            # ver cada factura en el momento, no cuando se llene el buffer.
            print(f"[{hora}] " + mensaje, flush=True)
            destino = config["procesados"] if ok else config["errores"]
            os.makedirs(destino, exist_ok=True)
            try:
                final = os.path.join(destino, os.path.basename(xml_path))
                if os.path.exists(final):
                    raiz, ext = os.path.splitext(final)
                    final = f"{raiz}_{datetime.now().strftime('%H%M%S')}{ext}"
                shutil.move(xml_path, final)
            except OSError as error:
                print(f"           no pude mover el original: {error}")

        time.sleep(config["intervalo"])


def main():
    config = leer_config()
    argumentos = sys.argv[1:]

    if argumentos and argumentos[0] in ("--vigilar", "-v"):
        try:
            modo_vigilar(config)
        except KeyboardInterrupt:
            print("\nRobot detenido.")
        return 0

    if not argumentos:
        print(__doc__)
        return 1

    modo_archivos(argumentos, config)
    return 0


if __name__ == "__main__":
    sys.exit(main())
