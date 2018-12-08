
NVCC        = nvcc
NVCC_FLAGS  = -O3 -I/usr/local/cuda/include -D_GNU_SOURCE
LD_FLAGS    = -lcusolver -L/usr/local/cuda/lib64
EXE	        = dmgpuv3
OBJ	        = dmgpuv3.o

default: $(EXE)

dmgpuv3.o: dmgpuv3.c
	$(NVCC) -c -o $@ dmgpuv3.c $(NVCC_FLAGS)

$(EXE): $(OBJ)
	$(NVCC) $(OBJ) -o $(EXE) $(LD_FLAGS)

clean:
	rm -rf *.o $(EXE)
