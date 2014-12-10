
/**
 * Copyright (c) 2013, Willem-Hendrik Thiart
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * @file
 * @brief ADT for managing Raft log entries (aka entries)
 * @author Willem Thiart himself@willemthiart.com
 * @version 0.1
 */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>

#include "raft.h"
#include "raft_log.h"

#define INITIAL_CAPACITY 10

typedef struct
{
    /* size of array */
    int size;
    
    /* the amount of elements in the array */
    int count;
    
    /* position of the queue */
    // we can just look at count because we aren't doing log compaction
    //int front, back;
    
    
    /* we compact the log, and thus need to increment the base idx */
    // actually you DONT do log compaction...
    //int base_log_idx;
    
    raft_entry_t* entries;
} log_private_t;

static void __ensurecapacity(log_private_t * me)
{
    if (me->count < me->size)
        return;
    
    raft_entry_t *temp = calloc(1,sizeof(raft_entry_t) * me->size * 2);
    memcpy(temp, me->entries, sizeof(raft_entry_t)*me->count);
    
    me->size *= 2;
    /* clean up old entries */
    free(me->entries);
    
    me->entries = temp;
}

log_t* log_new()
{
    log_private_t* me;
    
    me = calloc(1,sizeof(log_private_t));
    me->size = INITIAL_CAPACITY;
    me->count = 0;
    me->entries = calloc(1,sizeof(raft_entry_t) * me->size);
    return (void*)me;
}

int log_append_entry(log_t* me_, raft_entry_t* c)
{
    log_private_t* me = (void*)me_;
    
    //if (0 == c->entry.id)
    //    return 0;
    
    __ensurecapacity(me);
    
    memcpy(&me->entries[me->count],c,sizeof(raft_entry_t));
    me->entries[me->count].num_nodes = 0;
    me->count++;
    return 1;
}

raft_entry_t* log_get_from_idx(log_t* me_, int idx)
{
    log_private_t* me = (void*)me_;
    
    if (me->count <= idx)
        return NULL;
    
    return &me->entries[idx];
}

int log_count(log_t* me_)
{
    log_private_t* me = (void*)me_;
    return me->count;
}

// TODO! check the caller of this and make sure im doing the right thing...
void log_delete(log_t* me_, int idx)
{
    log_private_t* me = (void*)me_;
    me->count = idx;
}

/*void *log_poll(log_t * me_)
{
    log_private_t* me = (void*)me_;
    const void *elem;
    
    if (0 == log_count(me_))
        return NULL;
    elem = &me->entries[me->front];
    me->front++;
    me->count--;
    me->base_log_idx++;
    return (void *) elem;
}*/

raft_entry_t *log_peektail(log_t * me_)
{
    log_private_t* me = (void*)me_;
    
    if (0 == me->count)
        return NULL;
    
    return &me->entries[me->count - 1];
}

void log_empty(log_t * me_)
{
    log_private_t* me = (void*)me_;
    me->count = 0;
}

void log_free(log_t * me_)
{
    log_private_t* me = (void*)me_;
    
    free(me->entries);
    free(me);
}

void log_mark_node_has_committed(log_t* me_, int idx)
{
    raft_entry_t* e;
    
    if ((e = log_get_from_idx(me_,idx)))
    {
        e->num_nodes += 1;
    }
}

