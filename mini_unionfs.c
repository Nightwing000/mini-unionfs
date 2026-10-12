#define FUSE_USE_VERSION 31

#include <fuse.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdlib.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>
#include <libgen.h>
#include <limits.h>

// Global state passed to fuse_main
struct mini_unionfs_state {
    char *lower_dir;
    char *upper_dir;
};

#define UNIONFS_DATA ((struct mini_unionfs_state *) fuse_get_context()->private_data)

// Helper function to build a whiteout path
static void get_whiteout_path(const char *path, char *wh_path) {
    char path_for_dir[PATH_MAX];
    char path_for_base[PATH_MAX];
    
    // Use separate arrays to prevent memory overwrite
    strncpy(path_for_dir, path, PATH_MAX);
    strncpy(path_for_base, path, PATH_MAX);
    
    char *dname = dirname(path_for_dir);
    char *bname = basename(path_for_base);
    
    // If it's the root directory, clear the dname to avoid double slashes
    if (strcmp(dname, "/") == 0 || strcmp(dname, ".") == 0) {
        dname = "";
    }
    
    snprintf(wh_path, PATH_MAX, "%s%s/.wh.%s", UNIONFS_DATA->upper_dir, dname, bname);
}

// Helper function to resolve paths
static int resolve_path(const char *path, char *resolved_path, int *is_lower) {
    char wh_path[PATH_MAX];
    get_whiteout_path(path, wh_path);

    // 1. Check if whiteout exists
    if (access(wh_path, F_OK) == 0) {
        return -ENOENT;
    }

    // 2. Check if upper_dir path exists
    snprintf(resolved_path, PATH_MAX, "%s%s", UNIONFS_DATA->upper_dir, path);
    if (access(resolved_path, F_OK) == 0) {
        if (is_lower) *is_lower = 0;
        return 0;
    }

    // 3. Check if lower_dir path exists
    snprintf(resolved_path, PATH_MAX, "%s%s", UNIONFS_DATA->lower_dir, path);
    if (access(resolved_path, F_OK) == 0) {
        if (is_lower) *is_lower = 1;
        return 0;
    }

    // 4. Otherwise, return -ENOENT
    return -ENOENT;
}

static int unionfs_getattr(const char *path, struct stat *stbuf, struct fuse_file_info *fi) {
    (void) fi;
    char resolved_path[PATH_MAX];
    
    if (resolve_path(path, resolved_path, NULL) != 0) {
        return -ENOENT;
    }

    if (lstat(resolved_path, stbuf) == -1) {
        return -errno;
    }
    return 0;
}

static int unionfs_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
                           off_t offset, struct fuse_file_info *fi,
                           enum fuse_readdir_flags flags) {
    (void) offset;
    (void) fi;
    (void) flags;

    char lower_path[PATH_MAX];
    char upper_path[PATH_MAX];
    snprintf(lower_path, PATH_MAX, "%s%s", UNIONFS_DATA->lower_dir, path);
    snprintf(upper_path, PATH_MAX, "%s%s", UNIONFS_DATA->upper_dir, path);

    filler(buf, ".", NULL, 0, 0);
    filler(buf, "..", NULL, 0, 0);

    DIR *dp;
    struct dirent *de;

    // Read lower directory
    dp = opendir(lower_path);
    if (dp != NULL) {
        while ((de = readdir(dp)) != NULL) {
            char wh_path[PATH_MAX];
            char item_path[PATH_MAX];
            snprintf(item_path, PATH_MAX, "%s/%s", strcmp(path, "/") == 0 ? "" : path, de->d_name);
            get_whiteout_path(item_path, wh_path);
            
            // Only show if not whiteouted
            if (access(wh_path, F_OK) != 0 && strcmp(de->d_name, ".") != 0 && strcmp(de->d_name, "..") != 0) {
                filler(buf, de->d_name, NULL, 0, 0);
            }
        }
        closedir(dp);
    }

    // Read upper directory
    dp = opendir(upper_path);
    if (dp != NULL) {
        while ((de = readdir(dp)) != NULL) {
            if (strncmp(de->d_name, ".wh.", 4) != 0 && strcmp(de->d_name, ".") != 0 && strcmp(de->d_name, "..") != 0) {
                filler(buf, de->d_name, NULL, 0, 0);
            }
        }
        closedir(dp);
    }

    return 0;
}

static int copy_file(const char *src, const char *dst) {
    int fd_in = open(src, O_RDONLY);
    if (fd_in < 0) return -errno;

    int fd_out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd_out < 0) {
        close(fd_in);
        return -errno;
    }

    char buf[4096];
    ssize_t n;
    while ((n = read(fd_in, buf, sizeof(buf))) > 0) {
        if (write(fd_out, buf, n) != n) {
            close(fd_in);
            close(fd_out);
            return -EIO;
        }
    }

    close(fd_in);
    close(fd_out);
    return 0;
}

static int unionfs_open(const char *path, struct fuse_file_info *fi) {
    char resolved_path[PATH_MAX];
    int is_lower = 0;

    if (resolve_path(path, resolved_path, &is_lower) != 0) {
        return -ENOENT;
    }

    int write_intent = (fi->flags & O_WRONLY) || (fi->flags & O_RDWR) || (fi->flags & O_APPEND);

    // Copy-on-Write (CoW) trigger
    if (is_lower && write_intent) {
        char upper_path[PATH_MAX];
        snprintf(upper_path, PATH_MAX, "%s%s", UNIONFS_DATA->upper_dir, path);
       
        int res = copy_file(resolved_path, upper_path);
        if (res < 0) return res;
        
        strncpy(resolved_path, upper_path, PATH_MAX);
    }

    int fd = open(resolved_path, fi->flags);
    if (fd == -1) return -errno;

    fi->fh = fd;
    return 0;
}

static int unionfs_read(const char *path, char *buf, size_t size, off_t offset, struct fuse_file_info *fi) {
    (void) path;
    int res = pread(fi->fh, buf, size, offset);
    if (res == -1) res = -errno;
    return res;
}

static int unionfs_write(const char *path, const char *buf, size_t size, off_t offset, struct fuse_file_info *fi) {
    (void) path;
    int res = pwrite(fi->fh, buf, size, offset);
    if (res == -1) res = -errno;
    return res;
}

static int unionfs_create(const char *path, mode_t mode, struct fuse_file_info *fi) {
    char upper_path[PATH_MAX];
    snprintf(upper_path, PATH_MAX, "%s%s", UNIONFS_DATA->upper_dir, path);

    int fd = open(upper_path, fi->flags, mode);
    if (fd == -1) return -errno;

    fi->fh = fd;
    return 0;
}

static int unionfs_unlink(const char *path) {
    char resolved_path[PATH_MAX];
    int is_lower = 0;

    if (resolve_path(path, resolved_path, &is_lower) != 0) {
        return -ENOENT;
    }

    char upper_path[PATH_MAX];
    snprintf(upper_path, PATH_MAX, "%s%s", UNIONFS_DATA->upper_dir, path);

    if (access(upper_path, F_OK) == 0) {
        if (unlink(upper_path) == -1) return -errno;
    }

    if (is_lower || access(resolved_path, F_OK) == 0) {
        char wh_path[PATH_MAX];
        get_whiteout_path(path, wh_path);
        int fd = open(wh_path, O_CREAT | O_WRONLY, 0644);
        if (fd >= 0) close(fd);
    }

    return 0;
}

static int unionfs_mkdir(const char *path, mode_t mode) {
    char upper_path[PATH_MAX];
    snprintf(upper_path, PATH_MAX, "%s%s", UNIONFS_DATA->upper_dir, path);
    int res = mkdir(upper_path, mode);
    if (res == -1) return -errno;
    return 0;
}

static int unionfs_rmdir(const char *path) {
    char resolved_path[PATH_MAX];
    int is_lower = 0;
    if (resolve_path(path, resolved_path, &is_lower) != 0) return -ENOENT;

    if (is_lower) return -EROFS;

    int res = rmdir(resolved_path);
    if (res == -1) return -errno;
    return 0;
}

static struct fuse_operations unionfs_oper = {
    .getattr    = unionfs_getattr,
    .open       = unionfs_open,
    .unlink     = unionfs_unlink,
    .readdir    = unionfs_readdir,
    .read       = unionfs_read,
    .write      = unionfs_write,
    .create     = unionfs_create,
    .mkdir      = unionfs_mkdir,
    .rmdir      = unionfs_rmdir,
};

int main(int argc, char *argv[]) {
    if (argc < 4) {
        fprintf(stderr, "Usage: %s <lower_dir> <upper_dir> <mount_dir> [FUSE options]\n", argv[0]);
        return 1;
    }

    struct mini_unionfs_state *unionfs_data = malloc(sizeof(struct mini_unionfs_state));
    if (!unionfs_data) {
        perror("malloc");
        return 1;
    }
    
    unionfs_data->lower_dir = realpath(argv[1], NULL);
    unionfs_data->upper_dir = realpath(argv[2], NULL);

    argv[1] = argv[3];
    for (int i = 2; i < argc - 2; i++) {
        argv[i] = argv[i + 2];
    }
    argc -= 2;

    int ret = fuse_main(argc, argv, &unionfs_oper, unionfs_data);
    
    free(unionfs_data->lower_dir);
    free(unionfs_data->upper_dir);
    free(unionfs_data);
    
    return ret;
}
