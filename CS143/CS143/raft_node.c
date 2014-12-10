
/**
 * Copyright (c) 2013, Willem-Hendrik Thiart
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * @file
 * @brief Representation of a peer
 * @author Willem Thiart himself@willemthiart.com
 * @version 0.1
 */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>

#include "raft.h"

typedef struct {
    int next_idx;
} raft_node_private_t;

raft_node_t* raft_node_new()
{
    raft_node_private_t* me;
    me = calloc(1,sizeof(raft_node_private_t));
    return (void*)me;
}

int raft_node_get_next_idx(raft_node_t* me_)
{
    raft_node_private_t* me = (void*)me_;
    return me->next_idx;
}

void raft_node_set_next_idx(raft_node_t* me_, int nextIdx)
{
    raft_node_private_t* me = (void*)me_;
    me->next_idx = nextIdx;
}
