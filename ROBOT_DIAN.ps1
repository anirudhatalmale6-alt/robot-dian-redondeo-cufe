#Requires -Version 5.1
<#
    Robot DIAN en PowerShell - corrige el redondeo del XML y recalcula el CUFE.

    Esta version NO necesita instalar nada: PowerShell ya viene con Windows.
    Hace exactamente lo mismo que la version en Python.

    No se ejecuta a mano, se usa con los .bat:
        CORREGIR_ARRASTRANDO.bat     (arrastrar XML encima)
        VIGILAR_CARPETA.bat          (desatendido)
#>

param(
    [switch] $Vigilar,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Rutas
)

$ErrorActionPreference = 'Stop'

# Cultura invariante SIEMPRE. En un Windows en espanol el separador decimal es
# la coma, y sin esto "8403.36" se leeria como 840336 y se escribiria "8403,36"
# dentro del XML. La DIAN lo rechazaria y el CUFE saldria mal.
$INV = [System.Globalization.CultureInfo]::InvariantCulture

$BASE = Split-Path -Parent $MyInvocation.MyCommand.Path
$CONFIG_PATH = Join-Path $BASE 'config.ini'
$LOG_PATH = Join-Path $BASE 'registro.csv'

$NS_CBC = 'urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2'
$NS_CAC = 'urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2'


# ----------------------------------------------------------------- numeros

function ToDec([string] $texto) {
    if ([string]::IsNullOrWhiteSpace($texto)) { return [decimal] 0 }
    return [decimal]::Parse($texto.Trim(),
        [System.Globalization.NumberStyles]::Float, $INV)
}

function R2([decimal] $valor) {
    # Redondeo DIAN: media unidad hacia arriba (no el bancario de .NET).
    return [Math]::Round($valor, 2, [System.MidpointRounding]::AwayFromZero)
}

function Fmt([decimal] $valor) {
    return (R2 $valor).ToString('0.00', $INV)
}


# ----------------------------------------------------------------- xml

# Ojo con el ", $doc" y el ", $ns" al devolver: XmlDocument y
# XmlNamespaceManager son IEnumerable, y PowerShell desenrolla lo que devuelve
# una funcion. Sin la coma, en vez del objeto sale una lista de sus hijos.
function Get-Doc([string] $ruta) {
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.Load($ruta)
    return , $doc
}

function Get-Ns($doc) {
    $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('cbc', $NS_CBC)
    $ns.AddNamespace('cac', $NS_CAC)
    return , $ns
}

function Save-Doc($doc, [string] $ruta) {
    $ajustes = New-Object System.Xml.XmlWriterSettings
    # UTF-8 SIN BOM: algunos validadores de la DIAN se quejan con BOM.
    $ajustes.Encoding = New-Object System.Text.UTF8Encoding($false)
    $ajustes.Indent = $false
    $escritor = [System.Xml.XmlWriter]::Create($ruta, $ajustes)
    try { $doc.Save($escritor) } finally { $escritor.Close() }
}

function TextoDe($nodo, [string] $xpath, $ns) {
    if ($null -eq $nodo) { return $null }
    $encontrado = $nodo.SelectSingleNode($xpath, $ns)
    if ($null -eq $encontrado) { return $null }
    return $encontrado.InnerText
}

function Nuevo-Descuadre([string] $donde, [string] $campo, $hallado,
                         [string] $correcto, [string] $detalle) {
    $dif = ''
    if ($null -ne $hallado -and $hallado -ne '') {
        $dif = Fmt ((ToDec $hallado) - (ToDec $correcto))
    }
    return [PSCustomObject]@{
        Donde = $donde; Campo = $campo; Hallado = $hallado
        Correcto = $correcto; Detalle = $detalle; Dif = $dif
    }
}

function Texto-Descuadre($d) {
    $linea = "  [$($d.Donde)] $($d.Campo): XML=$($d.Hallado) | correcto=$($d.Correcto)"
    if ($d.Dif -ne '') { $linea += " | dif=$($d.Dif)" }
    if ($d.Detalle) { $linea += "`n        $($d.Detalle)" }
    return $linea
}


# ----------------------------------------------------------------- lineas

function Get-Lineas($raiz, $ns) {
    foreach ($tag in @('cac:InvoiceLine', 'cac:CreditNoteLine', 'cac:DebitNoteLine')) {
        $nodos = $raiz.SelectNodes($tag, $ns)
        if ($nodos.Count -gt 0) { return $nodos }
    }
    return @()
}

function Get-Cantidad($linea, $ns) {
    foreach ($tag in @('cbc:InvoicedQuantity', 'cbc:CreditedQuantity', 'cbc:DebitedQuantity')) {
        $nodo = $linea.SelectSingleNode($tag, $ns)
        if ($null -ne $nodo) { return ToDec $nodo.InnerText }
    }
    return [decimal] 0
}

function Get-DescuentosCargos($nodo, $ns) {
    $desc = [decimal] 0
    $cargos = [decimal] 0
    foreach ($ac in $nodo.SelectNodes('cac:AllowanceCharge', $ns)) {
        $monto = ToDec (TextoDe $ac 'cbc:Amount' $ns)
        $ind = TextoDe $ac 'cbc:ChargeIndicator' $ns
        if ($null -ne $ind -and $ind.Trim().ToLower() -eq 'true') {
            $cargos += $monto
        } else {
            $desc += $monto
        }
    }
    return @($desc, $cargos)
}


# ----------------------------------------------------------------- impuestos

function Get-Esquema($subtotal, $ns) {
    $texto = TextoDe $subtotal 'cac:TaxCategory/cac:TaxScheme/cbc:ID' $ns
    if ([string]::IsNullOrWhiteSpace($texto)) { return '00' }
    return $texto.Trim()
}

function Revisar-Impuestos($nodo, [string] $donde, $ns, $descuadres) {
    foreach ($taxTotal in $nodo.SelectNodes('cac:TaxTotal', $ns)) {
        $suma = [decimal] 0

        foreach ($sub in $taxTotal.SelectNodes('cac:TaxSubtotal', $ns)) {
            $base = ToDec (TextoDe $sub 'cbc:TaxableAmount' $ns)
            $pctTexto = TextoDe $sub 'cac:TaxCategory/cbc:Percent' $ns
            $montoNodo = $sub.SelectSingleNode('cbc:TaxAmount', $ns)
            $esquema = Get-Esquema $sub $ns

            if ($null -ne $pctTexto) {
                $esperado = R2 ($base * (ToDec $pctTexto) / [decimal] 100)
                $hallado = $null
                if ($null -ne $montoNodo) { $hallado = $montoNodo.InnerText }
                if ($null -eq $hallado -or (R2 (ToDec $hallado)) -ne $esperado) {
                    $descuadres.Add((Nuevo-Descuadre $donde "TaxAmount (impuesto $esquema)" `
                        $hallado (Fmt $esperado) "base $(Fmt $base) x $pctTexto%")) | Out-Null
                    if ($null -ne $montoNodo) { $montoNodo.InnerText = Fmt $esperado }
                }
                $suma += $esperado
            } elseif ($null -ne $montoNodo) {
                # Impuesto por unidad: no se recalcula, se respeta.
                $suma += R2 (ToDec $montoNodo.InnerText)
            }
        }

        $totalNodo = $taxTotal.SelectSingleNode('cbc:TaxAmount', $ns)
        if ($null -ne $totalNodo -and (R2 (ToDec $totalNodo.InnerText)) -ne (R2 $suma)) {
            $descuadres.Add((Nuevo-Descuadre $donde 'TaxTotal/TaxAmount' `
                $totalNodo.InnerText (Fmt $suma) 'debe ser la suma de los TaxSubtotal')) | Out-Null
            $totalNodo.InnerText = Fmt $suma
        }
    }
}

function Get-ImpuestoDocumento($raiz, $ns) {
    $porEsquema = @{}
    $total = [decimal] 0
    foreach ($taxTotal in $raiz.SelectNodes('cac:TaxTotal', $ns)) {
        foreach ($sub in $taxTotal.SelectNodes('cac:TaxSubtotal', $ns)) {
            $esquema = Get-Esquema $sub $ns
            $monto = R2 (ToDec (TextoDe $sub 'cbc:TaxAmount' $ns))
            if (-not $porEsquema.ContainsKey($esquema)) { $porEsquema[$esquema] = [decimal] 0 }
            $porEsquema[$esquema] += $monto
            $total += $monto
        }
    }
    return @($porEsquema, (R2 $total))
}

function Revisar-BaseDocumento($raiz, $ns, $descuadres) {
    # La base gravable del documento debe ser la suma de las bases de linea.
    $deLineas = @{}
    foreach ($linea in (Get-Lineas $raiz $ns)) {
        foreach ($taxTotal in $linea.SelectNodes('cac:TaxTotal', $ns)) {
            foreach ($sub in $taxTotal.SelectNodes('cac:TaxSubtotal', $ns)) {
                $esquema = Get-Esquema $sub $ns
                $base = R2 (ToDec (TextoDe $sub 'cbc:TaxableAmount' $ns))
                if (-not $deLineas.ContainsKey($esquema)) { $deLineas[$esquema] = [decimal] 0 }
                $deLineas[$esquema] += $base
            }
        }
    }
    if ($deLineas.Count -eq 0) { return }

    foreach ($taxTotal in $raiz.SelectNodes('cac:TaxTotal', $ns)) {
        foreach ($sub in $taxTotal.SelectNodes('cac:TaxSubtotal', $ns)) {
            $esquema = Get-Esquema $sub $ns
            if (-not $deLineas.ContainsKey($esquema)) { continue }
            $nodo = $sub.SelectSingleNode('cbc:TaxableAmount', $ns)
            $esperado = $deLineas[$esquema]
            $hallado = $null
            if ($null -ne $nodo) { $hallado = $nodo.InnerText }
            if ($null -eq $hallado -or (R2 (ToDec $hallado)) -ne $esperado) {
                $descuadres.Add((Nuevo-Descuadre 'totales' "TaxableAmount (impuesto $esquema)" `
                    $hallado (Fmt $esperado) `
                    'debe ser la suma de las bases gravables de las lineas')) | Out-Null
                if ($null -ne $nodo) { $nodo.InnerText = Fmt $esperado }
            }
        }
    }
}


# ----------------------------------------------------------------- totales

function Revisar-Lineas($raiz, $ns, $descuadres) {
    $lineas = Get-Lineas $raiz $ns
    if ($lineas.Count -eq 0) {
        $descuadres.Add((Nuevo-Descuadre 'documento' 'lineas' '0' '>=1' `
            'No encontre InvoiceLine / CreditNoteLine / DebitNoteLine.')) | Out-Null
        return [decimal] 0
    }

    $sumaTotal = [decimal] 0
    $indice = 0
    foreach ($linea in $lineas) {
        $indice++
        $id = TextoDe $linea 'cbc:ID' $ns
        if ([string]::IsNullOrWhiteSpace($id)) { $id = "$indice" }
        $donde = "linea $id"

        $cant = Get-Cantidad $linea $ns
        $precio = ToDec (TextoDe $linea 'cac:Price/cbc:PriceAmount' $ns)
        $leaNodo = $linea.SelectSingleNode('cbc:LineExtensionAmount', $ns)
        $hallado = $null
        if ($null -ne $leaNodo) { $hallado = $leaNodo.InnerText }

        $dc = Get-DescuentosCargos $linea $ns
        $desc = $dc[0]; $cargos = $dc[1]
        $esperado = R2 ((R2 ($cant * $precio)) - $desc + $cargos)

        if ($null -eq $hallado -or (R2 (ToDec $hallado)) -ne $esperado) {
            $detalle = "cantidad $($cant.ToString($INV)) x precio $($precio.ToString($INV))"
            if ($desc -ne 0 -or $cargos -ne 0) {
                $detalle += " - descuentos $(Fmt $desc) + cargos $(Fmt $cargos)"
            }
            $descuadres.Add((Nuevo-Descuadre $donde 'LineExtensionAmount' `
                $hallado (Fmt $esperado) $detalle)) | Out-Null
            if ($null -ne $leaNodo) { $leaNodo.InnerText = Fmt $esperado }
        }

        $sumaTotal += $esperado
        Revisar-Impuestos $linea $donde $ns $descuadres
    }
    return R2 $sumaTotal
}

$TOTAL_FIELDS = @('LineExtensionAmount', 'TaxExclusiveAmount', 'TaxInclusiveAmount',
                  'AllowanceTotalAmount', 'ChargeTotalAmount', 'PrepaidAmount',
                  'PayableAmount')

function Get-FotoTotales($raiz, $ns) {
    # Los totales TAL COMO VENIAN, antes de corregir nada. Es la unica
    # evidencia de con que formula los armo el software que emitio el XML.
    $lmt = $raiz.SelectSingleNode('cac:LegalMonetaryTotal', $ns)
    if ($null -eq $lmt) { $lmt = $raiz.SelectSingleNode('cac:RequestedMonetaryTotal', $ns) }
    $foto = @{}
    if ($null -ne $lmt) {
        foreach ($nombre in $TOTAL_FIELDS) {
            $foto[$nombre] = TextoDe $lmt "cbc:$nombre" $ns
        }
    }
    $imp = Get-ImpuestoDocumento $raiz $ns
    $foto['_tax'] = $imp[1]
    return $foto
}

function Get-BaseInclusive($foto, [decimal] $baseExclusive, [decimal] $sumaLineas) {
    # DOS convenciones para TaxInclusiveAmount, hay que respetar la del
    # software que emitio el XML y nunca imponer una:
    #   (a) UBL puro:  TaxInclusiveAmount = TaxExclusiveAmount + impuestos
    #   (b) DIAN:      TaxInclusiveAmount = LineExtensionAmount + impuestos
    # Con descuento a nivel documento las dos difieren EN TODO EL DESCUENTO.
    $tiaTexto = $foto['TaxInclusiveAmount']
    if ([string]::IsNullOrWhiteSpace($tiaTexto)) {
        return @('TaxExclusiveAmount', $baseExclusive)
    }
    $tia = R2 (ToDec $tiaTexto)
    $tax = [decimal] $foto['_tax']
    $candidatos = @(
        @('TaxExclusiveAmount', $baseExclusive),
        @('LineExtensionAmount', $sumaLineas)
    )
    foreach ($c in $candidatos) {
        $orig = $foto[$c[0]]
        if ([string]::IsNullOrWhiteSpace($orig)) { continue }
        if ((R2 ((ToDec $orig) + $tax)) -eq $tia) { return @($c[0], $c[1]) }
    }
    # Tolerancia de 1 peso: la DIAN la admite y los redondeos por linea la
    # producen solos. Sin esto un descuadre de centavos pareceria "formula
    # desconocida" y se dejaria sin corregir un documento que si se puede.
    foreach ($c in $candidatos) {
        $orig = $foto[$c[0]]
        if ([string]::IsNullOrWhiteSpace($orig)) { continue }
        if ([Math]::Abs((R2 ((ToDec $orig) + $tax)) - $tia) -le [decimal] 1) {
            return @($c[0], $c[1])
        }
    }
    return @($null, [decimal] 0)
}

function Resolver-Descuento($raiz, $lmt, $foto, [decimal] $sumaLineas,
                            [decimal] $baseExclusive, [decimal] $cargos,
                            $ns, $descuadres, $avisos) {
    # Mantiene  bruto - descuentos + cargos = base gravable.  Al corregir el
    # bruto y la base, el descuento queda desfasado; si no se reconcilia la
    # DIAN rechaza el documento por OTRA regla y volvemos a empezar.
    $allowNodo = $lmt.SelectSingleNode('cbc:AllowanceTotalAmount', $ns)
    $actual = [decimal] 0
    if ($null -ne $allowNodo) { $actual = R2 (ToDec $allowNodo.InnerText) }

    $oBruto = $foto['LineExtensionAmount']
    $oBase = $foto['TaxExclusiveAmount']
    $oDesc = $foto['AllowanceTotalAmount']
    if ([string]::IsNullOrWhiteSpace($oBruto) -or
        [string]::IsNullOrWhiteSpace($oBase) -or
        [string]::IsNullOrWhiteSpace($oDesc)) { return $actual }

    $oCargo = ToDec $foto['ChargeTotalAmount']
    # Solo se toca si el ORIGINAL ya cumplia la relacion: si no la cumplia,
    # no es la formula de este software y no hay nada que preservar.
    if ((R2 ((ToDec $oBruto) - (ToDec $oDesc) + $oCargo)) -ne (R2 (ToDec $oBase))) {
        return $actual
    }

    $requerido = R2 ($sumaLineas - $baseExclusive + $cargos)
    if ($requerido -eq $actual) { return $actual }

    $todos = $raiz.SelectNodes('cac:AllowanceCharge', $ns)
    $descuentos = @(); $listaCargos = @()
    foreach ($ac in $todos) {
        $ind = TextoDe $ac 'cbc:ChargeIndicator' $ns
        if ($null -ne $ind -and $ind.Trim().ToLower() -eq 'true') {
            $listaCargos += $ac
        } else { $descuentos += $ac }
    }

    if ($descuentos.Count -ne 1 -or $listaCargos.Count -gt 0) {
        [void] $avisos.Add(
            "El descuento del documento quedo desfasado al corregir el valor bruto.`r`n" +
            "    AllowanceTotalAmount dice $actual, y para que cuadre bruto - descuento = base`r`n" +
            "    tendria que ser $(Fmt $requerido). NO lo toque porque hay $($descuentos.Count) descuento(s)`r`n" +
            "    y $($listaCargos.Count) cargo(s), y no se a cual imputarle la diferencia. Revisalo a mano.")
        return $actual
    }

    $hallado = $null
    if ($null -ne $allowNodo) { $hallado = $allowNodo.InnerText }
    $descuadres.Add((Nuevo-Descuadre 'totales' 'AllowanceTotalAmount' $hallado `
        (Fmt $requerido) ("para que cuadre bruto $(Fmt $sumaLineas) - descuento = " +
        "base gravable $(Fmt $baseExclusive)"))) | Out-Null

    if ($null -ne $allowNodo) { $allowNodo.InnerText = Fmt $requerido }
    # El AllowanceCharge tiene que decir lo mismo que el total.
    $ac = $descuentos[0]
    $montoNodo = $ac.SelectSingleNode('cbc:Amount', $ns)
    if ($null -ne $montoNodo) { $montoNodo.InnerText = Fmt $requerido }
    $baseNodo = $ac.SelectSingleNode('cbc:BaseAmount', $ns)
    if ($null -ne $baseNodo) { $baseNodo.InnerText = Fmt $sumaLineas }
    return $requerido
}

function Revisar-Totales($raiz, [decimal] $sumaLineas, $ns, $descuadres,
                         $foto, $avisos) {
    $lmt = $raiz.SelectSingleNode('cac:LegalMonetaryTotal', $ns)
    if ($null -eq $lmt) { $lmt = $raiz.SelectSingleNode('cac:RequestedMonetaryTotal', $ns) }
    if ($null -eq $lmt) {
        $descuadres.Add((Nuevo-Descuadre 'totales' 'LegalMonetaryTotal' $null 'presente' `
            'No encontre el bloque de totales.')) | Out-Null
        return $null
    }

    $imp = Get-ImpuestoDocumento $raiz $ns
    $totalImpuesto = $imp[1]

    $leaNodo = $lmt.SelectSingleNode('cbc:LineExtensionAmount', $ns)
    if ($null -ne $leaNodo -and (R2 (ToDec $leaNodo.InnerText)) -ne $sumaLineas) {
        $descuadres.Add((Nuevo-Descuadre 'totales' 'LineExtensionAmount' `
            $leaNodo.InnerText (Fmt $sumaLineas) `
            'debe ser la suma de los totales de linea')) | Out-Null
        $leaNodo.InnerText = Fmt $sumaLineas
    }

    # Base gravable del documento = suma de las bases gravables de las lineas.
    $teaNodo = $lmt.SelectSingleNode('cbc:TaxExclusiveAmount', $ns)
    $baseLineas = [decimal] 0
    foreach ($linea in (Get-Lineas $raiz $ns)) {
        foreach ($tt in $linea.SelectNodes('cac:TaxTotal', $ns)) {
            foreach ($st in $tt.SelectNodes('cac:TaxSubtotal', $ns)) {
                $baseLineas += R2 (ToDec (TextoDe $st 'cbc:TaxableAmount' $ns))
            }
        }
    }
    if ($baseLineas -eq 0) { $baseLineas = $sumaLineas }
    $baseLineas = R2 $baseLineas

    $baseExclusive = $sumaLineas
    if ($null -ne $teaNodo) {
        if ((R2 (ToDec $teaNodo.InnerText)) -ne $baseLineas) {
            $descuadres.Add((Nuevo-Descuadre 'totales' 'TaxExclusiveAmount' `
                $teaNodo.InnerText (Fmt $baseLineas) `
                'debe ser la suma de las bases gravables de las lineas')) | Out-Null
            $teaNodo.InnerText = Fmt $baseLineas
        }
        $baseExclusive = $baseLineas
    }

    $dc = Get-DescuentosCargos $raiz $ns
    $docDesc = $dc[0]; $docCargos = $dc[1]

    $allowNodo = $lmt.SelectSingleNode('cbc:AllowanceTotalAmount', $ns)
    $allow = [decimal] 0
    if ($null -ne $allowNodo) {
        $allow = R2 (ToDec $allowNodo.InnerText)
        if ((R2 $docDesc) -ne $allow) {
            $descuadres.Add((Nuevo-Descuadre 'totales' 'AllowanceTotalAmount' `
                $allowNodo.InnerText (Fmt $docDesc) `
                'debe ser la suma de los AllowanceCharge de descuento')) | Out-Null
            $allowNodo.InnerText = Fmt $docDesc
            $allow = R2 $docDesc
        }
    }

    $chargeNodo = $lmt.SelectSingleNode('cbc:ChargeTotalAmount', $ns)
    $charge = [decimal] 0
    if ($null -ne $chargeNodo) {
        $charge = R2 (ToDec $chargeNodo.InnerText)
        if ((R2 $docCargos) -ne $charge) {
            $descuadres.Add((Nuevo-Descuadre 'totales' 'ChargeTotalAmount' `
                $chargeNodo.InnerText (Fmt $docCargos) `
                'debe ser la suma de los AllowanceCharge de cargo')) | Out-Null
            $chargeNodo.InnerText = Fmt $docCargos
            $charge = R2 $docCargos
        }
    }

    $prepaidNodo = $lmt.SelectSingleNode('cbc:PrepaidAmount', $ns)
    $prepaid = [decimal] 0
    if ($null -ne $prepaidNodo) { $prepaid = R2 (ToDec $prepaidNodo.InnerText) }

    $allow = Resolver-Descuento $raiz $lmt $foto $sumaLineas $baseExclusive `
        $charge $ns $descuadres $avisos

    $tiaNodo = $lmt.SelectSingleNode('cbc:TaxInclusiveAmount', $ns)
    $det = Get-BaseInclusive $foto $baseExclusive $sumaLineas
    $baseNombre = $det[0]
    $baseInclusive = [decimal] $det[1]

    if ($null -eq $baseNombre) {
        # El XML no cuadra con ninguna de las dos convenciones. No se adivina.
        [void] $avisos.Add(
            "NO pude deducir con que formula tu software calcula TaxInclusiveAmount.`r`n" +
            "    En el XML original vale $($foto['TaxInclusiveAmount']), y no coincide`r`n" +
            "    ni con base gravable + impuestos ni con valor bruto + impuestos.`r`n" +
            "    Por seguridad NO lo toque, ni tampoco PayableAmount. Revisalos a mano`r`n" +
            "    antes de enviar, porque de ahi sale el total a pagar.")
        $pagar = [decimal] 0
        $payNodoX = $lmt.SelectSingleNode('cbc:PayableAmount', $ns)
        if ($null -ne $payNodoX) { $pagar = R2 (ToDec $payNodoX.InnerText) }
        return [PSCustomObject]@{
            SumaLineas = $sumaLineas; Impuestos = $totalImpuesto; Pagar = $pagar
        }
    }

    $tiaEsperado = R2 ($baseInclusive + $totalImpuesto)
    $tia = $tiaEsperado
    if ($null -eq $tiaNodo -or (R2 (ToDec $tiaNodo.InnerText)) -ne $tiaEsperado) {
        $etiqueta = 'base gravable'
        if ($baseNombre -eq 'LineExtensionAmount') { $etiqueta = 'valor bruto' }
        $hallado = $null
        if ($null -ne $tiaNodo) { $hallado = $tiaNodo.InnerText }
        $descuadres.Add((Nuevo-Descuadre 'totales' 'TaxInclusiveAmount' `
            $hallado (Fmt $tiaEsperado) `
            "$etiqueta $(Fmt $baseInclusive) + impuestos $(Fmt $totalImpuesto) (formula de tu software)")) | Out-Null
        if ($null -ne $tiaNodo) { $tiaNodo.InnerText = Fmt $tiaEsperado }
    } else {
        $tia = R2 (ToDec $tiaNodo.InnerText)
    }

    $payNodo = $lmt.SelectSingleNode('cbc:PayableAmount', $ns)
    $payEsperado = R2 ($tia - $allow + $charge - $prepaid)
    $pay = $payEsperado
    if ($null -eq $payNodo -or (R2 (ToDec $payNodo.InnerText)) -ne $payEsperado) {
        $hallado = $null
        if ($null -ne $payNodo) { $hallado = $payNodo.InnerText }
        $descuadres.Add((Nuevo-Descuadre 'totales' 'PayableAmount' `
            $hallado (Fmt $payEsperado) `
            "$(Fmt $tia) - desc $(Fmt $allow) + cargos $(Fmt $charge) - anticipos $(Fmt $prepaid)")) | Out-Null
        if ($null -ne $payNodo) { $payNodo.InnerText = Fmt $payEsperado }
    } else {
        $pay = R2 (ToDec $payNodo.InnerText)
    }

    return [PSCustomObject]@{
        SumaLineas = $sumaLineas; Impuestos = $totalImpuesto; Pagar = $pay
    }
}


# ----------------------------------------------------------------- CUFE

function Get-IdParte($raiz, [string] $xpath, $ns) {
    $texto = TextoDe $raiz $xpath $ns
    if ([string]::IsNullOrWhiteSpace($texto)) { return '' }
    # El NIT entra al CUFE sin digito de verificacion.
    return ($texto.Trim() -split '-')[0]
}

function Get-Cufe($raiz, $ns, [string] $claveTecnica, [string] $ambiente) {
    $numFac = TextoDe $raiz 'cbc:ID' $ns
    $fecFac = TextoDe $raiz 'cbc:IssueDate' $ns
    $horFac = TextoDe $raiz 'cbc:IssueTime' $ns

    $lmt = $raiz.SelectSingleNode('cac:LegalMonetaryTotal', $ns)
    if ($null -eq $lmt) { $lmt = $raiz.SelectSingleNode('cac:RequestedMonetaryTotal', $ns) }
    $valFac = '0.00'; $valTot = '0.00'
    if ($null -ne $lmt) {
        $valFac = Fmt (ToDec (TextoDe $lmt 'cbc:LineExtensionAmount' $ns))
        $valTot = Fmt (ToDec (TextoDe $lmt 'cbc:PayableAmount' $ns))
    }

    $imp = Get-ImpuestoDocumento $raiz $ns
    $porEsquema = $imp[0]
    # Orden fijo que exige la DIAN: 01 IVA, 04 INC, 03 ICA.
    $parteImp = ''
    foreach ($codigo in @('01', '04', '03')) {
        $monto = [decimal] 0
        if ($porEsquema.ContainsKey($codigo)) { $monto = $porEsquema[$codigo] }
        $parteImp += $codigo + (Fmt $monto)
    }

    $nitOfe = Get-IdParte $raiz 'cac:AccountingSupplierParty/cac:Party/cac:PartyTaxScheme/cbc:CompanyID' $ns
    $numAdq = Get-IdParte $raiz 'cac:AccountingCustomerParty/cac:Party/cac:PartyTaxScheme/cbc:CompanyID' $ns

    $cadena = "$numFac$fecFac$horFac$valFac$parteImp$valTot$nitOfe$numAdq$claveTecnica$ambiente"

    $sha = [System.Security.Cryptography.SHA384]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($cadena))
    } finally { $sha.Dispose() }

    $hex = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) { [void] $hex.Append($b.ToString('x2', $INV)) }

    return @($cadena, $hex.ToString())
}

function Test-Firmado($raiz) {
    # Si el XML ya trae la firma, tocar un centavo la invalida.
    $nodos = $raiz.OwnerDocument.GetElementsByTagName(
        'SignatureValue', 'http://www.w3.org/2000/09/xmldsig#')
    return ($nodos.Count -gt 0)
}


# ----------------------------------------------------------------- proceso

function Invoke-Xml([string] $ruta, [string] $claveTecnica, [string] $ambiente) {
    $doc = Get-Doc $ruta
    $ns = Get-Ns $doc
    $raiz = $doc.DocumentElement
    $descuadres = New-Object System.Collections.ArrayList
    $avisos = New-Object System.Collections.ArrayList
    # La foto se toma ANTES de cualquier correccion: es la unica evidencia de
    # con que formula venia armado el documento.
    $foto = Get-FotoTotales $raiz $ns

    $sumaLineas = Revisar-Lineas $raiz $ns $descuadres
    Revisar-BaseDocumento $raiz $ns $descuadres
    Revisar-Impuestos $raiz 'totales' $ns $descuadres
    $totales = Revisar-Totales $raiz $sumaLineas $ns $descuadres $foto $avisos

    $uuidNodo = $raiz.SelectSingleNode('cbc:UUID', $ns)
    $cufeAnterior = $null
    $esquemaCufe = ''
    if ($null -ne $uuidNodo) {
        $cufeAnterior = $uuidNodo.InnerText.Trim()
        $esquemaCufe = $uuidNodo.GetAttribute('schemeName')
    }

    # El ambiente lo dice el propio XML en ProfileExecutionID, y es lo que va a
    # ver la DIAN. Se prefiere ese dato antes que el de config.ini: si el config
    # dice 2 y la factura es de produccion, el CUFE sale mal y el rechazo no
    # dice "ambiente", dice "CUFE incorrecto".
    $ambXml = TextoDe $raiz 'cbc:ProfileExecutionID' $ns
    if ($null -ne $ambXml) { $ambXml = $ambXml.Trim() }
    $ambCfg = $ambiente
    if (-not [string]::IsNullOrWhiteSpace($ambXml)) { $ambiente = $ambXml }
    if (-not [string]::IsNullOrWhiteSpace($ambXml) -and
        -not [string]::IsNullOrWhiteSpace($ambCfg) -and $ambXml -ne $ambCfg) {
        $nombres = @{ '1' = 'produccion'; '2' = 'habilitacion' }
        [void] $avisos.Add(
            "config.ini dice ambiente = $ambCfg ($($nombres[$ambCfg])) pero el XML viene marcado como`r`n" +
            "    $ambXml ($($nombres[$ambXml])) en ProfileExecutionID. Use el del XML, que es`r`n" +
            "    el que valida la DIAN. Corrige el config.ini para que no se repita.")
    }

    $cadena = $null; $cufeNuevo = $null
    if ($claveTecnica -and $ambiente) {
        $r = Get-Cufe $raiz $ns $claveTecnica $ambiente
        $cadena = $r[0]; $cufeNuevo = $r[1]
        if ($null -ne $uuidNodo) { $uuidNodo.InnerText = $cufeNuevo }
    }

    return [PSCustomObject]@{
        Doc = $doc
        Tipo = $raiz.LocalName
        Lineas = (Get-Lineas $raiz $ns).Count
        Descuadres = $descuadres
        Avisos = $avisos
        Totales = $totales
        Firmado = (Test-Firmado $raiz)
        CufeAnterior = $cufeAnterior
        EsquemaCufe = $esquemaCufe
        CufeNuevo = $cufeNuevo
        CadenaCufe = $cadena
    }
}

function Get-Informe($r, [string] $nombre, [string] $claveTecnica) {
    $out = New-Object System.Collections.ArrayList
    [void] $out.Add("Archivo: $nombre")
    [void] $out.Add("Tipo de documento: $($r.Tipo)  |  lineas: $($r.Lineas)")
    if ($null -ne $r.Totales) {
        [void] $out.Add("Valores correctos -> suma de lineas: $(Fmt $r.Totales.SumaLineas)" +
            "  |  impuestos: $(Fmt $r.Totales.Impuestos)" +
            "  |  total a pagar: $(Fmt $r.Totales.Pagar)")
    }
    if ($r.Firmado) {
        [void] $out.Add('')
        [void] $out.Add('*** ATENCION: este XML YA VIENE FIRMADO. Al corregir los')
        [void] $out.Add('    valores la firma deja de validar. Hay que volver a')
        [void] $out.Add('    firmarlo antes de enviarlo a la DIAN. ***')
    }
    [void] $out.Add('')

    foreach ($aviso in $r.Avisos) {
        [void] $out.Add('*** OJO: ' + $aviso)
        [void] $out.Add('')
    }

    if ($r.Descuadres.Count -gt 0) {
        [void] $out.Add("DESCUADRES ENCONTRADOS: $($r.Descuadres.Count)")
        foreach ($d in $r.Descuadres) { [void] $out.Add((Texto-Descuadre $d)) }
    } else {
        [void] $out.Add('Sin descuadres de redondeo. Todos los totales cierran a 2 decimales.')
    }
    [void] $out.Add('')

    if ($r.CufeAnterior) {
        $esq = $r.EsquemaCufe
        if (-not $esq) { $esq = 'sin schemeName' }
        [void] $out.Add("CUFE anterior ($esq): $($r.CufeAnterior)")
    }
    if ($r.CufeNuevo) {
        $cadena = $r.CadenaCufe
        if ($claveTecnica) { $cadena = $cadena.Replace($claveTecnica, '<CLAVE_TECNICA>') }
        [void] $out.Add("Cadena CUFE: $cadena")
        [void] $out.Add("CUFE nuevo:  $($r.CufeNuevo)")
        if ($r.CufeAnterior -and $r.CufeAnterior.ToLower() -ne $r.CufeNuevo) {
            [void] $out.Add('  -> El CUFE cambio. El XML corregido ya lleva el nuevo.')
        } elseif ($r.CufeAnterior) {
            [void] $out.Add('  -> El CUFE no cambio, ya estaba bien.')
        }
    } else {
        [void] $out.Add('AVISO: sin clave tecnica y ambiente NO se puede recalcular el CUFE.')
    }
    return ($out -join "`r`n")
}


# ----------------------------------------------------------------- config

function Get-Config {
    if (-not (Test-Path $CONFIG_PATH)) {
        throw "No encuentro config.ini en $BASE"
    }
    $valores = @{}
    foreach ($linea in (Get-Content $CONFIG_PATH)) {
        $t = $linea.Trim()
        if ($t -eq '' -or $t.StartsWith(';') -or $t.StartsWith('#') -or $t.StartsWith('[')) {
            continue
        }
        $pos = $t.IndexOf('=')
        if ($pos -lt 1) { continue }
        $valores[$t.Substring(0, $pos).Trim().ToLower()] = $t.Substring($pos + 1).Trim()
    }

    function Leer([string] $clave, [string] $porDefecto) {
        if ($valores.ContainsKey($clave) -and $valores[$clave] -ne '') {
            return $valores[$clave]
        }
        return $porDefecto
    }

    $clave = Leer 'clave_tecnica' ''
    if ($clave.ToUpper().StartsWith('PEGA')) { $clave = '' }
    $ambiente = Leer 'ambiente' ''
    if ($ambiente -ne '1' -and $ambiente -ne '2') { $ambiente = '' }

    function Ruta([string] $clave, [string] $porDefecto) {
        $valor = Leer $clave $porDefecto
        if (-not [System.IO.Path]::IsPathRooted($valor)) {
            $valor = Join-Path $BASE $valor
        }
        return $valor
    }

    return [PSCustomObject]@{
        ClaveTecnica = $clave
        Ambiente = $ambiente
        Entrada = (Ruta 'entrada' 'entrada')
        Salida = (Ruta 'salida' 'salida')
        Procesados = (Ruta 'procesados' 'procesados')
        Errores = (Ruta 'errores' 'errores')
        Intervalo = [int] (Leer 'intervalo_segundos' '5')
        MismoNombre = ((Leer 'nombre_salida' 'igual').ToLower() -ne 'sufijo')
    }
}


# ----------------------------------------------------------------- registro

function Add-Registro($fila) {
    $nuevo = -not (Test-Path $LOG_PATH)
    if ($nuevo) {
        $encabezado = 'fecha;archivo;documento;descuadres;venia_firmado;' +
                      'cufe_anterior;cufe_nuevo;resultado'
        # utf8 con BOM para que Excel en espanol abra bien las tildes
        [System.IO.File]::WriteAllText($LOG_PATH, "$encabezado`r`n",
            (New-Object System.Text.UTF8Encoding($true)))
    }
    [System.IO.File]::AppendAllText($LOG_PATH, (($fila -join ';') + "`r`n"),
        (New-Object System.Text.UTF8Encoding($false)))
}


# ----------------------------------------------------------------- modos

function Invoke-Correccion([string] $rutaXml, $config, [string] $carpetaSalida) {
    $nombre = Split-Path -Leaf $rutaXml
    $raizNombre = [System.IO.Path]::GetFileNameWithoutExtension($nombre)
    $destino = $carpetaSalida
    if (-not $destino) { $destino = Split-Path -Parent ([System.IO.Path]::GetFullPath($rutaXml)) }
    if (-not (Test-Path $destino)) { New-Item -ItemType Directory -Path $destino | Out-Null }

    if ($carpetaSalida -and $config.MismoNombre) {
        $salidaXml = Join-Path $destino $nombre
    } else {
        $salidaXml = Join-Path $destino "$($raizNombre)_corregido.xml"
    }
    $salidaTxt = Join-Path $destino "$($raizNombre)_informe.txt"
    $sello = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $INV)

    try {
        $r = Invoke-Xml $rutaXml $config.ClaveTecnica $config.Ambiente
    } catch {
        Add-Registro @($sello, $nombre, '', '', '', '', '', "ERROR: $($_.Exception.Message)")
        return @($false, "ERROR leyendo $nombre : $($_.Exception.Message)")
    }

    $texto = Get-Informe $r $nombre $config.ClaveTecnica
    Save-Doc $r.Doc $salidaXml
    [System.IO.File]::WriteAllText($salidaTxt, $texto + "`r`n",
        (New-Object System.Text.UTF8Encoding($false)))

    $cuantos = $r.Descuadres.Count
    $firmado = 'NO'
    if ($r.Firmado) { $firmado = 'SI' }
    $resultado = 'YA ESTABA BIEN'
    if ($cuantos -gt 0) { $resultado = 'CORREGIDO' }
    Add-Registro @($sello, $nombre, $r.Tipo, $cuantos, $firmado,
        $r.CufeAnterior, $r.CufeNuevo, $resultado)

    if ($cuantos -gt 0) {
        $resumen = "$nombre : $cuantos descuadre(s) corregido(s)"
    } else {
        $resumen = "$nombre : ya estaba bien"
    }
    if ($r.Firmado) { $resumen += '  [venia FIRMADO - hay que volver a firmarlo]' }
    if (-not $r.CufeNuevo) {
        $resumen += '  [sin clave tecnica en config.ini: CUFE NO recalculado]'
    }
    return @($true, $resumen)
}

function Get-XmlsEn([string] $ruta) {
    if (Test-Path $ruta -PathType Container) {
        return @(Get-ChildItem -Path $ruta -Filter *.xml -File |
            Where-Object { -not $_.Name.ToLower().EndsWith('_corregido.xml') } |
            Sort-Object Name | ForEach-Object { $_.FullName })
    }
    return @($ruta)
}

function Invoke-ModoArchivos($rutas, $config) {
    $total = 0
    foreach ($ruta in $rutas) {
        foreach ($xml in (Get-XmlsEn $ruta)) {
            $r = Invoke-Correccion $xml $config $null
            if ($r[0]) { Write-Host "  OK  $($r[1])" } else { Write-Host "  --  $($r[1])" }
            $total++
        }
    }
    if ($total -eq 0) {
        Write-Host 'No recibi ningun XML.'
    } else {
        Write-Host ''
        Write-Host "Listo. $total archivo(s) procesado(s)."
        Write-Host 'Revisa el _informe.txt de cada uno para ver que se cambio.'
    }
}

function Test-Estable([string] $ruta) {
    # El ERP puede estar escribiendo el archivo todavia cuando el robot lo ve.
    $ultimo = -1
    for ($i = 0; $i -lt 30; $i++) {
        try { $actual = (Get-Item $ruta).Length } catch { return $false }
        if ($actual -eq $ultimo -and $actual -gt 0) { return $true }
        $ultimo = $actual
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Invoke-ModoVigilar($config) {
    foreach ($c in @($config.Entrada, $config.Salida, $config.Procesados, $config.Errores)) {
        if (-not (Test-Path $c)) { New-Item -ItemType Directory -Path $c | Out-Null }
    }

    if ([System.IO.Path]::GetFullPath($config.Salida) -eq
        [System.IO.Path]::GetFullPath($config.Entrada)) {
        # Mensaje limpio, no una excepcion roja con rastro de pila: el cliente
        # tiene que entender que arreglar, no leer un volcado de PowerShell.
        Write-Host ''
        Write-Host "  config.ini: 'salida' no puede ser la misma carpeta que 'entrada'."
        Write-Host '  El robot se leeria su propio archivo corregido sin parar.'
        Write-Host '  Dejale a salida una carpeta distinta y vuelve a intentar.'
        Write-Host ''
        exit 1
    }

    Write-Host 'Robot DIAN vigilando.'
    Write-Host "  Deja los XML en : $($config.Entrada)"
    Write-Host "  Salen corregidos: $($config.Salida)"
    if (-not $config.ClaveTecnica) {
        Write-Host '  AVISO: config.ini sin clave tecnica -> el CUFE no se recalcula.'
    }
    Write-Host ''
    Write-Host 'Deja esta ventana abierta. Ctrl+C para parar.'
    Write-Host ''

    while ($true) {
        $pendientes = @()
        try { $pendientes = Get-XmlsEn $config.Entrada } catch { $pendientes = @() }

        foreach ($xml in $pendientes) {
            if (-not (Test-Estable $xml)) { continue }
            $r = Invoke-Correccion $xml $config $config.Salida
            $hora = (Get-Date).ToString('HH:mm:ss', $INV)
            Write-Host "[$hora] $($r[1])"

            $destino = $config.Errores
            if ($r[0]) { $destino = $config.Procesados }
            if (-not (Test-Path $destino)) { New-Item -ItemType Directory -Path $destino | Out-Null }
            try {
                $final = Join-Path $destino (Split-Path -Leaf $xml)
                if (Test-Path $final) {
                    $sinExt = [System.IO.Path]::GetFileNameWithoutExtension($final)
                    $ext = [System.IO.Path]::GetExtension($final)
                    $marca = (Get-Date).ToString('HHmmss', $INV)
                    $final = Join-Path $destino "$($sinExt)_$marca$ext"
                }
                Move-Item -LiteralPath $xml -Destination $final
            } catch {
                Write-Host "           no pude mover el original: $($_.Exception.Message)"
            }
        }
        Start-Sleep -Seconds $config.Intervalo
    }
}


# ----------------------------------------------------------------- main

$config = Get-Config

if ($Vigilar) {
    Invoke-ModoVigilar $config
    exit 0
}

if (-not $Rutas -or $Rutas.Count -eq 0) {
    Write-Host 'Arrastra uno o varios XML sobre CORREGIR_ARRASTRANDO.bat'
    exit 1
}

Invoke-ModoArchivos $Rutas $config
exit 0
