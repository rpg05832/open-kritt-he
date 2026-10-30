# Benchmark project: the CORRECT counterpart. Any finding here is a false positive.


def add_item(item, basket=None):
    basket = [] if basket is None else basket
    basket.append(item)
    return basket


def total_price(items, discount=0.1):
    subtotal = sum(item.price for item in items)
    return subtotal * (1 - discount)
