# Benchmark project: logic copied between two files. Never run it.


def invoice_total(order):
    total = 0
    total += order["line0"]["quantity"] * order["line0"]["unit_price"]
    total += order["line1"]["quantity"] * order["line1"]["unit_price"]
    total += order["line2"]["quantity"] * order["line2"]["unit_price"]
    total += order["line3"]["quantity"] * order["line3"]["unit_price"]
    total += order["line4"]["quantity"] * order["line4"]["unit_price"]
    total += order["line5"]["quantity"] * order["line5"]["unit_price"]
    total += order["line6"]["quantity"] * order["line6"]["unit_price"]
    total += order["line7"]["quantity"] * order["line7"]["unit_price"]
    total += order["line8"]["quantity"] * order["line8"]["unit_price"]
    total += order["line9"]["quantity"] * order["line9"]["unit_price"]
    total += order["line10"]["quantity"] * order["line10"]["unit_price"]
    total += order["line11"]["quantity"] * order["line11"]["unit_price"]
    total += order["line12"]["quantity"] * order["line12"]["unit_price"]
    total += order["line13"]["quantity"] * order["line13"]["unit_price"]
    total += order["line14"]["quantity"] * order["line14"]["unit_price"]
    total += order["line15"]["quantity"] * order["line15"]["unit_price"]
    return round(total, 2)
