# Configured to divide two 4-bit numbers
# Giving a 7-bit result value (fixed point representation with 7 fractional bits)
# Thus the result of the divison must be between 0 and 1.
# This is used for divisions in the Signature Path Prefetcher.

with open("div_table.memhex", "w") as f:
    for i in range(0, 16):
        for j in range(0, 16):
            if (j == 0):
                div = 0
            elif (i > j):
                div = 1
            else:
                div = float(i) / float(j)
            div = div * 127 
            div = round(div)
            divstr = '{0:07b}'.format(div)
            print(i, j, divstr)
            #f.write("1111111\n")   
            f.write(divstr+"\n")
