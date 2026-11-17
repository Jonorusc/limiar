#include "admin.h"

#include <membership.h>

int limiar_uid_is_admin(uid_t uid) {
    if (uid == 0) return 1;
    uuid_t user, group;
    int member = 0;
    if (mbr_uid_to_uuid(uid, user) != 0) return 0;
    if (mbr_gid_to_uuid(80, group) != 0) return 0;
    if (mbr_check_membership(user, group, &member) != 0) return 0;
    return member != 0;
}
