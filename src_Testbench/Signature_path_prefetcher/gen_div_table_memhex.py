# Configured to divide two 4-bit numbers
# Giving a 7-bit result value (fixed point representation with 7 fractional bits)
# Thus the result of the divison must be between 0 and 1.
# This is used for divisions in the Signature Path Prefetcher.

with open("div_table.bsvi", "w") as fout:
    fout.write ("// ***** This file was generated from a script *****\n")
    fout.write ("\n")
    fout.write ("\n")
    fout.write ("// This file is a BSV 'include' file\n")
    fout.write ("\n")
    fout.write ("\n")
    fout.write ("\n")
    fout.write ("function Bit #(7) fn_read_divtable (Bit #(8) addr);\n")
    fout.write ("   return\n")
    fout.write ("      case (addr)\n")
    addr = 0
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
            fout.write(f"            {addr}: 7'b_{divstr};\n")
            addr += 1
    fout.write ("         default: 7'h0;\n")
    fout.write ("      endcase;\n")
    fout.write ("endfunction: fn_read_divtable\n")
    fout.write ("\n")
