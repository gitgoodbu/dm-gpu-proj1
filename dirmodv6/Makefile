
NVCC        = nvcc
NVCC_FLAGS  = -O3 -I/usr/local/cuda/include -D_GNU_SOURCE
LD_FLAGS    = -lcudart -lcublas -lcusolver -L/usr/local/cuda/lib64
EXE	        = dmgpuv6
OBJ	        = dmgpuv6.o

default: $(EXE)

dmgpuv6.o: dmgpuv6.cu
	$(NVCC) -c -o $@ dmgpuv6.cu $(NVCC_FLAGS)

$(EXE): $(OBJ)
	$(NVCC) $(OBJ) -o $(EXE) $(LD_FLAGS)

clean:
	rm -rf *.o $(EXE)
