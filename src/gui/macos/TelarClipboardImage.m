#import "TelarClipboardImage.h"
#import "../../host/macos/clipboard_image.h"
#import <CommonCrypto/CommonDigest.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <time.h>

static const uint64_t cache_limit = 256ULL * 1024 * 1024;
static const time_t cache_retention = 30 * 24 * 60 * 60;

static BOOL private_directory(int fd) {
    struct stat info;
    return fd >= 0 && fstat(fd, &info) == 0 && S_ISDIR(info.st_mode) &&
        info.st_uid == geteuid() && (info.st_mode & 077) == 0;
}

static BOOL cache_name(const char *name) {
    if (strlen(name) != CC_SHA256_DIGEST_LENGTH * 2 + 4 || (strcmp(name + CC_SHA256_DIGEST_LENGTH * 2, ".png") != 0 && strcmp(name + CC_SHA256_DIGEST_LENGTH * 2, ".tmp") != 0)) return NO;
    for (unsigned i = 0; i < CC_SHA256_DIGEST_LENGTH * 2; i++) {
        if (!((name[i] >= '0' && name[i] <= '9') || (name[i] >= 'a' && name[i] <= 'f'))) return NO;
    }
    return YES;
}

static BOOL available_space(int directory, size_t length) {
    DIR *entries = fdopendir(dup(directory));
    if (entries == NULL) return NO;
    uint64_t total = 0;
    unsigned count = 0;
    const time_t now = time(NULL);
    struct dirent *entry;
    BOOL valid = YES;
    while ((entry = readdir(entries)) != NULL) {
        if (++count > 1024) { valid = NO; break; }
        if (!cache_name(entry->d_name)) continue;
        struct stat info;
        if (fstatat(directory, entry->d_name, &info, AT_SYMLINK_NOFOLLOW) != 0 ||
            !S_ISREG(info.st_mode) || info.st_uid != geteuid() || info.st_nlink != 1 || info.st_size < 0) { valid = NO; break; }
        if (now > info.st_mtime && now - info.st_mtime > cache_retention && unlinkat(directory, entry->d_name, 0) == 0) continue;
        if ((uint64_t)info.st_size > cache_limit - total) { valid = NO; break; }
        total += (uint64_t)info.st_size;
    }
    closedir(entries);
    return valid && length <= cache_limit - total;
}

static NSData *store_png(const unsigned char *bytes, size_t length, uint32_t *status) {
    NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    if (base == nil) return nil;
    NSString *directory_path = [base.path stringByAppendingPathComponent:@"telar-agent-images"];
    if (mkdir(directory_path.fileSystemRepresentation, 0700) != 0 && errno != EEXIST) return nil;
    int directory = open(directory_path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (!private_directory(directory)) { if (directory >= 0) close(directory); return nil; }
    if (flock(directory, LOCK_EX) != 0) { close(directory); return nil; }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes, (CC_LONG)length, digest);
    char name[CC_SHA256_DIGEST_LENGTH * 2 + 5];
    for (unsigned i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(name + i * 2, 3, "%02x", digest[i]);
    memcpy(name + CC_SHA256_DIGEST_LENGTH * 2, ".png", 5);
    struct stat existing;
    BOOL saved = NO;
    if (fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) == 0) {
        saved = S_ISREG(existing.st_mode) && existing.st_uid == geteuid() && existing.st_nlink == 1 &&
            (existing.st_mode & 077) == 0 && existing.st_size == (off_t)length;
        if (saved) utimensat(directory, name, NULL, AT_SYMLINK_NOFOLLOW);
    } else if (errno == ENOENT) {
        if (!available_space(directory, length)) {
            *status = TELAR_CLIPBOARD_TOO_LARGE;
        } else {
            char temporary[sizeof name];
            memcpy(temporary, name, sizeof name);
            memcpy(temporary + CC_SHA256_DIGEST_LENGTH * 2, ".tmp", 5);
            // A prior interrupted writer can leave only this private partial file.
            struct stat partial;
            if (fstatat(directory, temporary, &partial, AT_SYMLINK_NOFOLLOW) == 0 &&
                S_ISREG(partial.st_mode) && partial.st_uid == geteuid() && partial.st_nlink == 1) {
                unlinkat(directory, temporary, 0);
            }
            int fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
            if (fd >= 0) {
                size_t offset = 0;
                while (offset < length) {
                    ssize_t count = write(fd, bytes + offset, length - offset);
                    if (count < 0 && errno == EINTR) continue;
                    if (count <= 0) break;
                    offset += (size_t)count;
                }
                saved = offset == length && fsync(fd) == 0;
                if (close(fd) != 0) saved = NO;
                if (saved) saved = renameat(directory, temporary, directory, name) == 0;
                if (!saved) unlinkat(directory, temporary, 0);
            }
        }
    }
    flock(directory, LOCK_UN);
    close(directory);
    if (!saved) return nil;
    NSString *path = [directory_path stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];
    NSData *result = [path dataUsingEncoding:NSUTF8StringEncoding];
    if (result.length > 1024) { *status = TELAR_CLIPBOARD_TOO_LARGE; return nil; }
    *status = TELAR_CLIPBOARD_OK;
    return result;
}

NSData *telar_clipboard_image_path(NSPasteboard *pasteboard, uint32_t *status) {
    unsigned char *bytes = NULL;
    size_t length = 0;
    uint32_t width = 0, height = 0;
    *status = telar_clipboard_copy_png(pasteboard, &bytes, &length, &width, &height,
        32 * 1024 * 1024, 16 * 1024 * 1024, 16 * 1000 * 1000);
    if (*status != TELAR_CLIPBOARD_OK) return nil;
    *status = TELAR_CLIPBOARD_FAILED;
    NSData *result = store_png(bytes, length, status);
    volatile unsigned char *wipe = bytes;
    for (size_t i = 0; i < length; i++) wipe[i] = 0;
    free(bytes);
    return result;
}
