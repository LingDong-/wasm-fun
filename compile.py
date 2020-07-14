import os
from glob import glob

wats = glob("wat/*.wat")

for w in wats:
    cmd = "./wat2wasm "+w+" -o wasm/"+w.split("/")[-1].replace(".wat",".wasm")
    print(cmd)
    os.system(cmd)

