#ifndef LIMIAR_ADMIN_H
#define LIMIAR_ADMIN_H

#include <sys/types.h>

/// 1 if `uid` is root or a member of the `admin` group (gid 80), else 0.
int limiar_uid_is_admin(uid_t uid);

#endif
