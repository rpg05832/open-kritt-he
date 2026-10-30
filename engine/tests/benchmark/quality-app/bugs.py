# Benchmark project: planted Python correctness bugs. Never run it.


def add_item(item, basket=[]):
    basket.append(item)
    return basket


def total_price(items):
    subtotal = sum(item.price for item in items)
    discount = 0.1
    return subtotal * (1 - dicount)
