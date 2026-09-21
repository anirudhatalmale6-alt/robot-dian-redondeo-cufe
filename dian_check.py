#!/usr/bin/env python3
"""
Validador de redondeo DIAN (UBL 2.1) + recalculo de CUFE/CUDE.

Uso:
    python3 dian_check.py factura.xml
    python3 dian_check.py factura.xml --fix salida.xml --clave-tecnica XXXX --ambiente 2

Revisa:
  - Por linea:  LineExtensionAmount == round(InvoicedQuantity * PriceAmount, 2)
  - Por linea:  cargos/descuentos (AllowanceCharge) aplicados al total de linea
  - Por impuesto: TaxAmount == round(TaxableAmount * Percent / 100, 2)
  - Totales: LegalMonetaryTotal coherente con lineas e impuestos
  - CUFE/CUDE: recalcula SHA-384 y lo compara con el del XML
"""

import argparse
import hashlib
import sys
from decimal import Decimal, ROUND_HALF_UP

import xml.etree.ElementTree as ET

NS = {
    "cbc": "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2",
    "cac": "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2",
    "ext": "urn:oasis:names:specification:ubl:schema:xsd:CommonExtensionComponents-2",
    "sts": "dian:gov:co:facturaelectronica:Structures-2-1",
}
for p, u in NS.items():
    ET.register_namespace(p, u)

CENT = Decimal("0.01")


def d(text):
    """Texto -> Decimal, tolerante a None/vacio."""
    if text is None or str(text).strip() == "":
        return Decimal("0")
    return Decimal(str(text).strip())


def r2(value):
    """Redondeo DIAN: media unidad hacia arriba, 2 decimales."""
    return Decimal(value).quantize(CENT, rounding=ROUND_HALF_UP)


def fmt(value):
    return f"{r2(value):.2f}"


def text_of(node, path):
    found = node.find(path, NS)
    return found.text if found is not None else None


class Issue:
    def __init__(self, where, field, found, expected, detail=""):
        self.where = where
        self.field = field
        self.found = found
        self.expected = expected
        self.detail = detail

    @property
    def diff(self):
        try:
            return r2(d(self.found) - d(self.expected))
        except Exception:
            return None

    def __str__(self):
        base = f"[{self.where}] {self.field}: XML={self.found} | correcto={self.expected}"
        if self.diff is not None:
            base += f" | dif={self.diff}"
        if self.detail:
            base += f"\n        {self.detail}"
        return base


# ---------------------------------------------------------------- lineas


def line_nodes(root):
    """Devuelve (tag_de_linea, lista_de_nodos) segun sea factura o nota."""
    for tag in ("cac:InvoiceLine", "cac:CreditNoteLine", "cac:DebitNoteLine"):
        nodes = root.findall(tag, NS)
        if nodes:
            return tag, nodes
    return None, []


def line_quantity(line):
    """La cantidad cambia de nombre entre factura y nota credito/debito."""
    for tag in ("cbc:InvoicedQuantity", "cbc:CreditedQuantity", "cbc:DebitedQuantity"):
        node = line.find(tag, NS)
        if node is not None:
            return d(node.text)
    return Decimal("0")


def allowance_totals(node):
    """(descuentos, cargos) de los AllowanceCharge hijos directos."""
    discounts = Decimal("0")
    charges = Decimal("0")
    for ac in node.findall("cac:AllowanceCharge", NS):
        amount = d(text_of(ac, "cbc:Amount"))
        indicator = (text_of(ac, "cbc:ChargeIndicator") or "false").strip().lower()
        if indicator == "true":
            charges += amount
        else:
            discounts += amount
    return discounts, charges


def check_lines(root, issues, fix=False):
    """Valida cada linea. Devuelve la suma de LineExtensionAmount correctos."""
    tag, lines = line_nodes(root)
    if not lines:
        issues.append(Issue("documento", "lineas", "0", ">=1",
                            "No encontre InvoiceLine / CreditNoteLine / DebitNoteLine."))
        return Decimal("0")

    total_lines = Decimal("0")

    for index, line in enumerate(lines, start=1):
        line_id = text_of(line, "cbc:ID") or str(index)
        where = f"linea {line_id}"

        qty = line_quantity(line)
        price = d(text_of(line, "cac:Price/cbc:PriceAmount"))
        lea_node = line.find("cbc:LineExtensionAmount", NS)
        lea_found = lea_node.text if lea_node is not None else None

        discounts, charges = allowance_totals(line)
        expected = r2(r2(qty * price) - discounts + charges)

        if lea_found is None or r2(d(lea_found)) != expected:
            detail = f"cantidad {qty} x precio {price}"
            if discounts or charges:
                detail += f" - descuentos {fmt(discounts)} + cargos {fmt(charges)}"
            issues.append(Issue(where, "LineExtensionAmount", lea_found,
                                fmt(expected), detail))
            if fix and lea_node is not None:
                lea_node.text = fmt(expected)

        total_lines += expected

        # Impuestos de la linea
        check_tax_totals(line, where, issues, fix=fix)

    return r2(total_lines)


# ---------------------------------------------------------------- impuestos


def check_tax_totals(node, where, issues, fix=False):
    """Valida TaxTotal/TaxSubtotal de un nodo (linea o documento)."""
    for tax_total in node.findall("cac:TaxTotal", NS):
        subtotal_sum = Decimal("0")

        for subtotal in tax_total.findall("cac:TaxSubtotal", NS):
            taxable = d(text_of(subtotal, "cbc:TaxableAmount"))
            percent_text = text_of(subtotal, "cac:TaxCategory/cbc:Percent")
            amount_node = subtotal.find("cbc:TaxAmount", NS)
            amount_found = amount_node.text if amount_node is not None else None

            per_unit = subtotal.find("cac:TaxCategory/cac:TaxScheme", NS)
            scheme = text_of(per_unit, "cbc:ID") if per_unit is not None else "?"

            if percent_text is not None:
                expected = r2(taxable * d(percent_text) / Decimal("100"))
                if amount_found is None or r2(d(amount_found)) != expected:
                    issues.append(Issue(
                        where, f"TaxAmount (impuesto {scheme})", amount_found,
                        fmt(expected),
                        f"base {fmt(taxable)} x {percent_text}%"))
                    if fix and amount_node is not None:
                        amount_node.text = fmt(expected)
                subtotal_sum += expected
            else:
                # Impuesto por unidad (PerUnitAmount) - no se recalcula, se respeta.
                subtotal_sum += r2(d(amount_found))

        total_node = tax_total.find("cbc:TaxAmount", NS)
        total_found = total_node.text if total_node is not None else None
        if total_node is not None and r2(d(total_found)) != r2(subtotal_sum):
            issues.append(Issue(where, "TaxTotal/TaxAmount", total_found,
                                fmt(subtotal_sum),
                                "debe ser la suma de los TaxSubtotal"))
            if fix:
                total_node.text = fmt(subtotal_sum)


def scheme_of(subtotal):
    node = subtotal.find("cac:TaxCategory/cac:TaxScheme/cbc:ID", NS)
    if node is not None and node.text:
        return node.text.strip()
    return "00"


def document_tax_total(root):
    """Suma de TaxTotal/TaxAmount a nivel documento, por esquema de impuesto."""
    by_scheme = {}
    grand = Decimal("0")
    for tax_total in root.findall("cac:TaxTotal", NS):
        for subtotal in tax_total.findall("cac:TaxSubtotal", NS):
            scheme = scheme_of(subtotal)
            amount = r2(d(text_of(subtotal, "cbc:TaxAmount")))
            by_scheme[scheme] = by_scheme.get(scheme, Decimal("0")) + amount
            grand += amount
    return by_scheme, r2(grand)


def line_taxable_by_scheme(root):
    """Suma de las bases gravables de las lineas, por esquema de impuesto."""
    by_scheme = {}
    _, lines = line_nodes(root)
    for line in lines:
        for tax_total in line.findall("cac:TaxTotal", NS):
            for subtotal in tax_total.findall("cac:TaxSubtotal", NS):
                scheme = scheme_of(subtotal)
                base = r2(d(text_of(subtotal, "cbc:TaxableAmount")))
                by_scheme[scheme] = by_scheme.get(scheme, Decimal("0")) + base
    return by_scheme


def check_document_taxable_base(root, issues, fix=False):
    """La base gravable del documento debe ser la suma de las bases de linea."""
    from_lines = line_taxable_by_scheme(root)
    if not from_lines:
        return
    for tax_total in root.findall("cac:TaxTotal", NS):
        for subtotal in tax_total.findall("cac:TaxSubtotal", NS):
            scheme = scheme_of(subtotal)
            if scheme not in from_lines:
                continue
            node = subtotal.find("cbc:TaxableAmount", NS)
            found = node.text if node is not None else None
            expected = from_lines[scheme]
            if found is None or r2(d(found)) != expected:
                issues.append(Issue(
                    "totales", f"TaxableAmount (impuesto {scheme})", found,
                    fmt(expected),
                    "debe ser la suma de las bases gravables de las lineas"))
                if fix and node is not None:
                    node.text = fmt(expected)


# ---------------------------------------------------------------- totales


TOTAL_FIELDS = ("LineExtensionAmount", "TaxExclusiveAmount", "TaxInclusiveAmount",
                "AllowanceTotalAmount", "ChargeTotalAmount", "PrepaidAmount",
                "PayableAmount")


def snapshot_totals(root):
    """Guarda los totales y el impuesto TAL COMO VENIAN, antes de corregir nada.

    Hace falta para deducir con que formula trabaja el software que emitio el
    XML. Si se mira despues de corregir, ya se perdio la evidencia.
    """
    lmt = root.find("cac:LegalMonetaryTotal", NS)
    if lmt is None:
        lmt = root.find("cac:RequestedMonetaryTotal", NS)
    snap = {}
    if lmt is not None:
        for name in TOTAL_FIELDS:
            snap[name] = text_of(lmt, f"cbc:{name}")
    _, snap["_tax"] = document_tax_total(root)
    return snap


def reconcile_allowance(root, lmt, orig, sum_lines, base_exclusive, charge_v,
                        issues, avisos, fix):
    """Mantiene la relacion  bruto - descuentos + cargos = base gravable.

    Al corregir el bruto y la base, el descuento del documento se queda
    desfasado. Si no se reconcilia, la DIAN rechaza el documento por OTRA
    regla y volvemos a empezar.

    Solo se toca si el documento ORIGINAL ya cumplia esa relacion: si no la
    cumplia, no es la formula de este software y no hay nada que preservar.
    Devuelve el valor de descuento a usar de aqui en adelante.
    """
    allow_node = lmt.find("cbc:AllowanceTotalAmount", NS)
    actual = r2(d(allow_node.text)) if allow_node is not None else Decimal("0")

    o_gross = orig.get("LineExtensionAmount")
    o_base = orig.get("TaxExclusiveAmount")
    o_allow = orig.get("AllowanceTotalAmount")
    if o_gross is None or o_base is None or o_allow is None:
        return actual

    o_charge = d(orig.get("ChargeTotalAmount"))
    cumplia = r2(d(o_gross) - d(o_allow) + o_charge) == r2(d(o_base))
    if not cumplia:
        return actual

    required = r2(sum_lines - base_exclusive + charge_v)
    if required == actual:
        return actual

    # Solo se reparte solo si hay UN descuento y ningun cargo. Con varios no
    # hay forma de saber a cual imputarle la diferencia.
    cargos = [ac for ac in root.findall("cac:AllowanceCharge", NS)
              if (text_of(ac, "cbc:ChargeIndicator") or "false").strip().lower() == "true"]
    descuentos = [ac for ac in root.findall("cac:AllowanceCharge", NS)
                  if (text_of(ac, "cbc:ChargeIndicator") or "false").strip().lower() != "true"]

    if len(descuentos) != 1 or cargos:
        avisos.append(
            "El descuento del documento quedo desfasado al corregir el valor "
            "bruto.\n"
            f"    AllowanceTotalAmount dice {actual}, y para que cuadre "
            f"bruto - descuento = base\n"
            f"    tendria que ser {fmt(required)}. NO lo toque porque hay "
            f"{len(descuentos)} descuento(s)\n"
            f"    y {len(cargos)} cargo(s), y no se a cual imputarle la "
            "diferencia. Revisalo a mano.")
        return actual

    issues.append(Issue("totales", "AllowanceTotalAmount", allow_node.text if allow_node is not None else None,
                        fmt(required),
                        f"para que cuadre bruto {fmt(sum_lines)} - descuento = "
                        f"base gravable {fmt(base_exclusive)}"))
    if fix:
        if allow_node is not None:
            allow_node.text = fmt(required)
        # El AllowanceCharge tiene que decir lo mismo que el total.
        ac = descuentos[0]
        monto_node = ac.find("cbc:Amount", NS)
        if monto_node is not None:
            monto_node.text = fmt(required)
        base_node = ac.find("cbc:BaseAmount", NS)
        if base_node is not None:
            base_node.text = fmt(sum_lines)
    return required


def inclusive_base(orig, base_exclusive, sum_lines):
    """Deduce que campo usa el software como base del TaxInclusiveAmount.

    Devuelve (nombre_del_campo, valor_corregido_de_esa_base), o (None, None)
    si el XML original no cuadra con ninguna de las dos convenciones.
    """
    tia = orig.get("TaxInclusiveAmount")
    if tia is None:
        # Sin dato original no hay nada que deducir: se usa el estandar UBL.
        return "TaxExclusiveAmount", base_exclusive

    tia = r2(d(tia))
    tax = orig.get("_tax", Decimal("0"))
    candidatos = (
        ("TaxExclusiveAmount", base_exclusive),
        ("LineExtensionAmount", sum_lines),
    )
    for nombre, corregido in candidatos:
        original = orig.get(nombre)
        if original is None:
            continue
        if r2(d(original) + tax) == tia:
            return nombre, corregido

    # Tolerancia de 1 peso: la DIAN la admite y los redondeos por linea la
    # producen sola. Sin esto un descuadre de centavos pareceria "formula
    # desconocida" y se dejaria de corregir un documento que si se puede.
    for nombre, corregido in candidatos:
        original = orig.get(nombre)
        if original is None:
            continue
        if abs(r2(d(original) + tax) - tia) <= Decimal("1.00"):
            return nombre, corregido

    return None, None


def check_monetary_total(root, sum_lines, issues, orig, avisos, fix=False):
    lmt = root.find("cac:LegalMonetaryTotal", NS)
    if lmt is None:
        lmt = root.find("cac:RequestedMonetaryTotal", NS)
    if lmt is None:
        issues.append(Issue("totales", "LegalMonetaryTotal", None, "presente",
                            "No encontre el bloque de totales."))
        return None

    where = "totales"
    _, total_tax = document_tax_total(root)

    def node_and_value(name):
        node = lmt.find(f"cbc:{name}", NS)
        return node, (node.text if node is not None else None)

    lea_node, lea = node_and_value("LineExtensionAmount")
    if lea is None or r2(d(lea)) != sum_lines:
        issues.append(Issue(where, "LineExtensionAmount", lea, fmt(sum_lines),
                            "debe ser la suma de los totales de linea"))
        if fix and lea_node is not None:
            lea_node.text = fmt(sum_lines)

    # TaxExclusiveAmount = base gravable del documento. Debe cuadrar con la
    # suma de las bases gravables de las lineas, que es lo que ya se corrigio
    # en los TaxSubtotal.
    tea_node, tea = node_and_value("TaxExclusiveAmount")
    base_lines = sum(line_taxable_by_scheme(root).values()) or sum_lines
    base_lines = r2(base_lines)
    if tea is not None and r2(d(tea)) != base_lines:
        issues.append(Issue(where, "TaxExclusiveAmount", tea, fmt(base_lines),
                            "debe ser la suma de las bases gravables de las lineas"))
        if fix and tea_node is not None:
            tea_node.text = fmt(base_lines)
        base_exclusive = base_lines
    elif tea is not None:
        base_exclusive = r2(d(tea))
    else:
        base_exclusive = sum_lines

    allow_node, allow = node_and_value("AllowanceTotalAmount")
    charge_node, charge = node_and_value("ChargeTotalAmount")
    prepaid_node, prepaid = node_and_value("PrepaidAmount")
    allow_v = r2(d(allow))
    charge_v = r2(d(charge))
    prepaid_v = r2(d(prepaid))

    doc_allow, doc_charge = allowance_totals(root)
    if allow is not None and r2(doc_allow) != allow_v:
        issues.append(Issue(where, "AllowanceTotalAmount", allow, fmt(doc_allow),
                            "debe ser la suma de los AllowanceCharge de descuento"))
        if fix and allow_node is not None:
            allow_node.text = fmt(doc_allow)
            allow_v = r2(doc_allow)
    if charge is not None and r2(doc_charge) != charge_v:
        issues.append(Issue(where, "ChargeTotalAmount", charge, fmt(doc_charge),
                            "debe ser la suma de los AllowanceCharge de cargo"))
        if fix and charge_node is not None:
            charge_node.text = fmt(doc_charge)
            charge_v = r2(doc_charge)

    # ------------------------------------------------------------------
    # TaxInclusiveAmount: hay DOS convenciones en uso y hay que respetar la
    # del software que emitio el XML, nunca imponer una.
    #   (a) UBL puro:  TaxInclusiveAmount = TaxExclusiveAmount + impuestos
    #   (b) DIAN:      TaxInclusiveAmount = LineExtensionAmount + impuestos
    #                  ("Total valor bruto mas tributos")
    # Con descuento a nivel documento las dos difieren EN TODO EL DESCUENTO.
    # Elegir la equivocada mueve el total a pagar millones de pesos.
    # ------------------------------------------------------------------
    allow_v = reconcile_allowance(root, lmt, orig, sum_lines, base_exclusive,
                                  charge_v, issues, avisos, fix)

    tia_node, tia = node_and_value("TaxInclusiveAmount")
    base_name, base_inclusive = inclusive_base(orig, base_exclusive, sum_lines)

    if base_name is None:
        # El XML original no cuadra con ninguna de las dos. No se adivina:
        # se deja como esta y se avisa para revision manual.
        avisos.append(
            "NO pude deducir con que formula tu software calcula "
            "TaxInclusiveAmount.\n"
            f"    En el XML original vale {orig.get('TaxInclusiveAmount')}, y no "
            "coincide\n"
            "    ni con base gravable + impuestos ni con valor bruto + "
            "impuestos.\n"
            "    Por seguridad NO lo toque, ni tampoco PayableAmount. "
            "Revisalos a mano\n"
            "    antes de enviar, porque de ahi sale el total a pagar.")
        tia_value = r2(d(tia)) if tia is not None else Decimal("0")
    else:
        expected_tia = r2(base_inclusive + total_tax)
        etiqueta = ("valor bruto" if base_name == "LineExtensionAmount"
                    else "base gravable")
        if tia is None or r2(d(tia)) != expected_tia:
            issues.append(Issue(where, "TaxInclusiveAmount", tia, fmt(expected_tia),
                                f"{etiqueta} {fmt(base_inclusive)} + impuestos "
                                f"{fmt(total_tax)} (formula de tu software)"))
            if fix and tia_node is not None:
                tia_node.text = fmt(expected_tia)
            tia_value = expected_tia
        else:
            tia_value = r2(d(tia))

    pay_node, pay = node_and_value("PayableAmount")
    if base_name is None:
        # Sin saber la formula del TaxInclusiveAmount, tocar el total a pagar
        # seria adivinar con el dinero del cliente.
        return {
            "line_extension": sum_lines,
            "tax_total": total_tax,
            "payable": r2(d(pay)) if pay is not None else Decimal("0"),
        }

    expected_pay = r2(tia_value - allow_v + charge_v - prepaid_v)
    if pay is None or r2(d(pay)) != expected_pay:
        issues.append(Issue(where, "PayableAmount", pay, fmt(expected_pay),
                            f"{fmt(tia_value)} - desc {fmt(allow_v)} + cargos "
                            f"{fmt(charge_v)} - anticipos {fmt(prepaid_v)}"))
        if fix and pay_node is not None:
            pay_node.text = fmt(expected_pay)
        pay_value = expected_pay
    else:
        pay_value = r2(d(pay))

    return {
        "line_extension": sum_lines,
        "tax_total": total_tax,
        "payable": pay_value,
    }


# ---------------------------------------------------------------- CUFE


def party_id(root, party_path):
    node = root.find(party_path, NS)
    if node is None:
        return None
    raw = node.text.strip() if node.text else ""
    # El NIT entra al CUFE sin digito de verificacion.
    return raw.split("-")[0]


def build_cufe(root, clave_tecnica, ambiente):
    """Arma la cadena del CUFE v2 y devuelve (cadena, sha384)."""
    num_fac = text_of(root, "cbc:ID") or ""
    fec_fac = text_of(root, "cbc:IssueDate") or ""
    hor_fac = text_of(root, "cbc:IssueTime") or ""

    lmt = root.find("cac:LegalMonetaryTotal", NS)
    if lmt is None:
        lmt = root.find("cac:RequestedMonetaryTotal", NS)
    val_fac = fmt(d(text_of(lmt, "cbc:LineExtensionAmount"))) if lmt is not None else "0.00"
    val_tot = fmt(d(text_of(lmt, "cbc:PayableAmount"))) if lmt is not None else "0.00"

    by_scheme, _ = document_tax_total(root)
    # Orden fijo que exige la DIAN: 01 IVA, 04 INC, 03 ICA.
    order = ["01", "04", "03"]
    tax_part = ""
    for code in order:
        tax_part += code + fmt(by_scheme.get(code, Decimal("0")))

    nit_ofe = party_id(
        root,
        "cac:AccountingSupplierParty/cac:Party/cac:PartyTaxScheme/cbc:CompanyID")
    num_adq = party_id(
        root,
        "cac:AccountingCustomerParty/cac:Party/cac:PartyTaxScheme/cbc:CompanyID")

    cadena = (f"{num_fac}{fec_fac}{hor_fac}{val_fac}{tax_part}{val_tot}"
              f"{nit_ofe or ''}{num_adq or ''}{clave_tecnica}{ambiente}")
    digest = hashlib.sha384(cadena.encode("utf-8")).hexdigest()
    return cadena, digest


def current_cufe(root):
    node = root.find("cbc:UUID", NS)
    if node is None:
        return None, None
    scheme = node.attrib.get("schemeName", "")
    return (node.text or "").strip(), scheme


# ---------------------------------------------------------------- main


def load(path):
    with open(path, "rb") as handle:
        data = handle.read()
    # Algunos ERP escriben el XML con BOM o con la firma ya puesta.
    tree = ET.ElementTree(ET.fromstring(data))
    return tree, tree.getroot()


def is_signed(root):
    """True si el XML ya trae la firma digital incrustada.

    Importa mucho: si tocamos un solo centavo de un XML ya firmado, la firma
    deja de validar. Hay que corregir ANTES de firmar, no despues.
    """
    for elem in root.iter():
        if elem.tag.endswith("}SignatureValue"):
            return True
    return False


def check_dates(root, avisos):
    """Avisa si la fecha de vencimiento quedo ANTES que la de emision.

    No se corrige nunca: cual de las dos esta mal es decision del que factura,
    y ademas la fecha de emision entra dentro del CUFE. Solo se avisa.
    """
    emision = text_of(root, "cbc:IssueDate")
    if not emision:
        return
    emision = emision.strip()

    candidatos = [("DueDate", text_of(root, "cbc:DueDate"))]
    for pm in root.findall("cac:PaymentMeans", NS):
        candidatos.append(("PaymentMeans/PaymentDueDate",
                           text_of(pm, "cbc:PaymentDueDate")))

    for nombre, vence in candidatos:
        if not vence:
            continue
        vence = vence.strip()
        # Formato ISO YYYY-MM-DD: comparar como texto ya ordena bien.
        if vence < emision:
            avisos.append(
                f"La fecha de vencimiento ({nombre}) es ANTERIOR a la de "
                "emision.\n"
                f"    Emision {emision}, vencimiento {vence}. Una de las dos "
                "esta mal.\n"
                "    NO la toque: cual corregir lo decides tu, y ademas la "
                "fecha de emision\n"
                "    entra dentro del CUFE, asi que hay que arreglarla en tu "
                "software y\n"
                "    volver a pasar el XML por el robot.")


def procesar(xml_path, clave_tecnica=None, ambiente=None):
    """Valida y corrige un XML en memoria. Devuelve un dict con el resultado.

    No escribe nada a disco: de eso se encarga quien llama.
    """
    tree, root = load(xml_path)
    issues = []
    avisos = []
    # La foto se toma ANTES de cualquier correccion: es la unica evidencia de
    # con que formula venia armado el documento.
    orig = snapshot_totals(root)

    # Las correcciones se aplican SIEMPRE sobre el arbol en memoria: asi el
    # informe y el CUFE describen el documento corregido, no el roto. Cada
    # Issue guarda el valor original en el momento de detectarlo.
    sum_lines = check_lines(root, issues, fix=True)
    check_document_taxable_base(root, issues, fix=True)
    check_tax_totals(root, "totales", issues, fix=True)
    totals = check_monetary_total(root, sum_lines, issues, orig, avisos, fix=True)

    check_dates(root, avisos)

    # El ambiente lo dice el propio XML en ProfileExecutionID, y es lo que va
    # a ver la DIAN. Se prefiere ese dato antes que el de config.ini: si el
    # config dice 2 y la factura es de produccion, el CUFE sale mal y el
    # rechazo no dice "ambiente", dice "CUFE incorrecto".
    amb_xml = text_of(root, "cbc:ProfileExecutionID")
    amb_xml = amb_xml.strip() if amb_xml else None
    amb_cfg = str(ambiente).strip() if ambiente else None
    ambiente = amb_xml or amb_cfg
    if amb_xml and amb_cfg and amb_xml != amb_cfg:
        nombres = {"1": "produccion", "2": "habilitacion"}
        avisos.append(
            f"config.ini dice ambiente = {amb_cfg} "
            f"({nombres.get(amb_cfg, '?')}) pero el XML viene marcado como\n"
            f"    {amb_xml} ({nombres.get(amb_xml, '?')}) en ProfileExecutionID. "
            "Use el del XML, que es\n"
            "    el que valida la DIAN. Corrige el config.ini para que no se "
            "repita.")

    cufe_xml, scheme = current_cufe(root)
    cadena = digest = None
    if clave_tecnica and ambiente:
        # Se calcula sobre el arbol YA corregido, que es el que se va a firmar.
        cadena, digest = build_cufe(root, clave_tecnica, str(ambiente))
        node = root.find("cbc:UUID", NS)
        if node is not None:
            node.text = digest

    _, lines = line_nodes(root)
    return {
        "tree": tree,
        "root": root,
        "doc_type": root.tag.split("}")[-1],
        "line_count": len(lines),
        "issues": issues,
        "avisos": avisos,
        "totals": totals,
        "signed": is_signed(root),
        "cufe_anterior": cufe_xml,
        "cufe_scheme": scheme,
        "cufe_nuevo": digest,
        "cadena_cufe": cadena,
    }


def informe(result, xml_path, clave_tecnica=None):
    """Arma el texto del informe (el mismo que se imprime y se guarda a .txt)."""
    out = []
    out.append(f"Archivo: {xml_path}")
    out.append(f"Tipo de documento: {result['doc_type']}  |  "
               f"lineas: {result['line_count']}")
    totals = result["totals"]
    if totals:
        out.append(f"Valores correctos -> suma de lineas: {fmt(totals['line_extension'])}"
                   f"  |  impuestos: {fmt(totals['tax_total'])}"
                   f"  |  total a pagar: {fmt(totals['payable'])}")
    if result["signed"]:
        out.append("")
        out.append("*** ATENCION: este XML YA VIENE FIRMADO. Al corregir los")
        out.append("    valores la firma deja de validar. Hay que volver a")
        out.append("    firmarlo antes de enviarlo a la DIAN. ***")
    out.append("")

    for aviso in result.get("avisos", []):
        out.append("*** OJO: " + aviso)
        out.append("")

    issues = result["issues"]
    if issues:
        out.append(f"DESCUADRES ENCONTRADOS: {len(issues)}")
        for issue in issues:
            out.append("  " + str(issue))
    else:
        out.append("Sin descuadres de redondeo. Todos los totales cierran a 2 decimales.")
    out.append("")

    if result["cufe_anterior"]:
        out.append(f"CUFE anterior ({result['cufe_scheme'] or 'sin schemeName'}): "
                   f"{result['cufe_anterior']}")
    if result["cufe_nuevo"]:
        cadena = result["cadena_cufe"]
        if clave_tecnica:
            cadena = cadena.replace(clave_tecnica, "<CLAVE_TECNICA>")
        out.append(f"Cadena CUFE: {cadena}")
        out.append(f"CUFE nuevo:  {result['cufe_nuevo']}")
        if result["cufe_anterior"] and result["cufe_anterior"].lower() != result["cufe_nuevo"]:
            out.append("  -> El CUFE cambio. El XML corregido ya lleva el nuevo.")
        elif result["cufe_anterior"]:
            out.append("  -> El CUFE no cambio, ya estaba bien.")
    else:
        out.append("AVISO: sin clave tecnica y ambiente NO se puede recalcular el CUFE.")
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description="Validador redondeo DIAN + CUFE")
    parser.add_argument("xml")
    parser.add_argument("--fix", metavar="SALIDA",
                        help="escribe el XML corregido en esta ruta")
    parser.add_argument("--clave-tecnica", default=None,
                        help="ClaveTecnica (factura) o SoftwarePIN (nota)")
    parser.add_argument("--ambiente", default=None, choices=["1", "2"],
                        help="1 = produccion, 2 = habilitacion")
    args = parser.parse_args()

    result = procesar(args.xml, args.clave_tecnica, args.ambiente)
    print(informe(result, args.xml, args.clave_tecnica))

    if args.fix:
        result["tree"].write(args.fix, encoding="UTF-8", xml_declaration=True)
        print(f"\nXML corregido escrito en: {args.fix}")

    return 1 if result["issues"] else 0


if __name__ == "__main__":
    sys.exit(main())
