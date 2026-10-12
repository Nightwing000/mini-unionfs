CC = gcc
CFLAGS = -Wall -Wextra -g `pkg-config fuse3 --cflags`
LIBS = `pkg-config fuse3 --libs`
TARGET = mini_unionfs

all: $(TARGET)

$(TARGET): mini_unionfs.c
	$(CC) $(CFLAGS) mini_unionfs.c -o $(TARGET) $(LIBS)

clean:
	rm -f $(TARGET)
