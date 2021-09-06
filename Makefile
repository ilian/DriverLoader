CC=x86_64-w64-mingw32-gcc

all: main
main.o: main.c

clean:
	rm -f main.exe main.o
