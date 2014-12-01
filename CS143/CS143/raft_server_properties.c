
/**
 * Copyright (c) 2013, Willem-Hendrik Thiart
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * @file
 * @author Willem Thiart himself@willemthiart.com
 * @version 0.1
 */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>

/* for varags */
#include <stdarg.h>

#include "raft.h"
#include "raft_log.h"
#include "raft_private.h"

void raft_set_election_timeout(raft_server_t* me_, int millisec)
{
    raft_server_private_t* me = (void*)me_;
    me->election_timeout = millisec;
}

void raft_set_request_timeout(raft_server_t* me_, int millisec)
{
    raft_server_private_t* me = (void*)me_;
    me->request_timeout = millisec;
}

int raft_get_nodeid(raft_server_t* me_)
{
    return ((raft_server_private_t*)me_)->nodeid;
}

int raft_get_election_timeout(raft_server_t* me_)
{
    return ((raft_server_private_t*)me_)->election_timeout;
}

int raft_get_request_timeout(raft_server_t* me_)
{
    return ((raft_server_private_t*)me_)->request_timeout;
}

int raft_get_num_nodes(raft_server_t* me_)
{
    return ((raft_server_private_t*)me_)->num_nodes;
}


int raft_get_timeout_elapsed(raft_server_t* me_)
{
    return ((raft_server_private_t*)me_)->timeout_elapsed;
}

int raft_get_log_count(raft_server_t* me_)
{
    raft_server_private_t* me = (void*)me_;
    return log_count(me->log);
}

int raft_get_voted_for(raft_server_t* me_)
{
    return ((raft_server_private_t*)me_)->voted_for;
}

void raft_set_current_term(raft_server_t* me_, int term)
{
    raft_server_private_t* me = (void*)me_;
    me->current_term = term;
}

int raft_get_current_term(raft_server_t* me_)
{
    return ((raft_server_private_t*)me_)->current_term;
}

void raft_set_current_idx(raft_server_t* me_, int idx)
{
    raft_server_private_t* me = (void*)me_;
    me->current_idx = idx;
}

int raft_get_current_idx(raft_server_t* me_)
{
    return ((raft_server_private_t*)me_)->current_idx;
}

int raft_get_my_id(raft_server_t* me_)
{
    return ((raft_server_private_t*)me_)->nodeid;
}

void raft_set_commit_idx(raft_server_t* me_, int idx)
{
    raft_server_private_t* me = (void*)me_;
    me->commit_idx = idx;
}

void raft_set_last_applied_idx(raft_server_t* me_, int idx)
{
    raft_server_private_t* me = (void*)me_;
    me->last_applied_idx = idx;
}

int raft_get_last_applied_idx(raft_server_t* me_)
{
    return ((raft_server_private_t*)me_)->last_applied_idx;
}

int raft_get_commit_idx(raft_server_t* me_)
{
    return ((raft_server_private_t*)me_)->commit_idx;
}

void raft_set_state(raft_server_t* me_, int state)
{
    raft_server_private_t* me = (void*)me_;
    me->state = state;
}

int raft_get_state(raft_server_t* me_)
{
    return ((raft_server_private_t*)me_)->state;
}

