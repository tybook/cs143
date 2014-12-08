
/**
 * Copyright (c) 2013, Willem-Hendrik Thiart
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * @file
 * @brief Implementation of a Raft server
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

#define DEBUG 1


static void __log(raft_server_t *me_, const char *fmt, ...)
{
    raft_server_private_t* me = (void*)me_;
    char buf[1024];
    va_list args;
    
    va_start(args, fmt);
    vsprintf(buf, fmt, args);
#if DEBUG /* debugging */
    printf("%d: %s\n", me->nodeid, buf);
    //__FUNC_log(bto,src,buf);
#endif
}

raft_server_t* raft_new(int nodeid)
{
    raft_server_private_t* me;
    
    
    if (!(me = calloc(1, sizeof(raft_server_private_t))))
        return NULL;
    
    me->current_term = 0;
    me->voted_for = -1;
    me->current_idx = 0;
    me->commit_idx = -1;
    me->last_applied_idx = -1;
    me->timeout_elapsed = 0;
    me->request_timeout = REQUEST_TIMEOUT;
    me->election_timeout = ELECTION_TIMEOUT;
    me->log = log_new();
    me->nodeid = nodeid;
    raft_set_state((void*)me, RAFT_STATE_FOLLOWER);
    __log((void*)me, "created new server");
    return (void*)me;
}

void raft_set_callbacks(raft_server_t* me_,
                        raft_cbs_t* funcs, void* udata)
{
    raft_server_private_t* me = (void*)me_;
    
    memcpy(&me->cb, funcs, sizeof(raft_cbs_t));
    me->udata = udata;
}

void raft_free(raft_server_t* me_)
{
    raft_server_private_t* me = (void*)me_;
    
    log_free(me->log);
    free(me_);
}

void raft_election_start(raft_server_t* me_)
{
    raft_server_private_t* me = (void*)me_;
    
    __log(me_, "election starting: %d %d, term: %d",
          me->election_timeout, me->timeout_elapsed, me->current_term);
    
    raft_become_candidate(me_);
}

void raft_become_leader(raft_server_t* me_)
{
    raft_server_private_t* me = (void*)me_;
    int i;
    
    __log(me_, "becoming leader");
    
    raft_set_state(me_,RAFT_STATE_LEADER);
    me->voted_for = -1;
    for (i=0; i<me->num_nodes; i++)
    {
        if (me->nodeid == i) continue;
        raft_node_t* p = raft_get_node(me_, i);
        raft_node_set_next_idx(p, raft_get_current_idx(me_));
        raft_send_appendentries(me_, i);
    }
}

void raft_become_candidate(raft_server_t* me_)
{
    raft_server_private_t* me = (void*)me_;
    int i;
    
    __log(me_, "becoming candidate");
    
    memset(me->votes_for_me, 0, sizeof(int) * me->num_nodes);
    me->current_term += 1;
    raft_vote(me_, me->nodeid);
    raft_set_state(me_, RAFT_STATE_CANDIDATE);
    
    /* we need a random factor here to prevent simultaneous candidates */
    me->timeout_elapsed = rand() % 500;
    
    for (i=0; i<me->num_nodes; i++)
    {
        if (me->nodeid == i) continue;
        raft_send_requestvote(me_, i);
    }
    
    /* so that when there is one device only, automatically become master */
    if (raft_votes_is_majority(me->num_nodes, raft_get_nvotes_for_me(me_)))
        raft_become_leader(me_);
}

void raft_become_follower(raft_server_t* me_)
{
    raft_server_private_t* me = (void*)me_;
    
    __log(me_, "becoming follower");
    
    raft_set_state(me_, RAFT_STATE_FOLLOWER);
    me->voted_for = -1;
}

int raft_periodic(raft_server_t* me_, int msec_since_last_period)
{
    raft_server_private_t* me = (void*)me_;
    
    //__log(me_, "periodic elapsed time: %d", me->timeout_elapsed);
    
    switch (me->state)
    {
        case RAFT_STATE_FOLLOWER:
            if (me->last_applied_idx < me->commit_idx)
            {
                if (0 == raft_apply_entry(me_))
                    return 0;
            }
            break;
    }
    
    me->timeout_elapsed += msec_since_last_period;
    
    if (me->state == RAFT_STATE_LEADER)
    {
        if (me->request_timeout <= me->timeout_elapsed)
        {
            raft_send_appendentries_all(me_);
            me->timeout_elapsed = 0;
        }
    }
    else
    {
        if (me->election_timeout <= me->timeout_elapsed)
        {
            raft_election_start(me_);
        }
    }
    
    return 1;
}

raft_entry_t* raft_get_entry_from_idx(raft_server_t* me_, int etyidx)
{
    raft_server_private_t* me = (void*)me_;
    return log_get_from_idx(me->log, etyidx);
}

int raft_recv_appendentries_response(raft_server_t* me_,
                                     int node, msg_appendentries_response_t* r)
{
    raft_server_private_t* me = (void*)me_;
    raft_node_t* p;
    
    __log(me_, "RECEIVED APPENDENTRIES RESPONSE FROM: %d", node);
    __log(me_, "success %d", r->success);
    __log(me_, "current_idx %d", r->current_idx);
    __log(me_, "first_idx %d", r->first_idx);
    
    p = raft_get_node(me_, node);
    
    // 2 == r->success if it was a duplicate
    
    if (1 == r->success)
    {
        int i;
        
        for (i=r->first_idx; i<r->current_idx; i++) {
            __log(me_, "marking index %d as committed", i);
            log_mark_node_has_committed(me->log, i);
        }

        raft_node_set_next_idx(p, r->current_idx);
        
        while (1)
        {
            raft_entry_t* e;
            
            e = log_get_from_idx(me->log, me->last_applied_idx + 1);
            
            /* majority has this */
            if (e)
                __log(me_, "entry %d has %d commits", me->last_applied_idx + 1,
                    e->num_nodes);
            if (e && me->num_nodes / 2 <= e->num_nodes)
            {
                if (0 == raft_apply_entry(me_)) break;
            }
            else
            {
                break;
            }
        }
    }
    else if (r->success == 0)
    {
        /* If AppendEntries fails because of log inconsistency:
         decrement nextIndex and retry (§5.3) */
        assert(0 <= raft_node_get_next_idx(p));
        // TODO does this have test coverage?
        // TODO can jump back to where node is different instead of iterating
        raft_node_set_next_idx(p, raft_node_get_next_idx(p)-1);
        raft_send_appendentries(me_, node);
    }
    
    return 1;
}

int raft_recv_appendentries(raft_server_t* me_, const int node, msg_appendentries_t* ae)
{
    raft_server_private_t* me = (void*)me_;
    msg_appendentries_response_t r;
    
    me->timeout_elapsed = 0;
    
    __log(me_, "RECEIVED APPENDENTRIES FROM: %d", node);
    __log(me_, "term %d", ae->term);
    __log(me_, "leader_id %d", ae->leader_id);
    __log(me_, "prev_log_idx %d", ae->prev_log_idx);
    __log(me_, "prev_log_term %d", ae->prev_log_term);
    __log(me_, "n_entries %d", ae->n_entries);
    __log(me_, "leader_commit %d", ae->leader_commit);
    
    r.term = me->current_term;
    
    /* we've found a leader who is legitimate */
    if (raft_is_leader(me_) && me->current_term <= ae->term)
        raft_become_follower(me_);
    
    /* 1. Reply false if term < currentTerm (§5.1) */
    if (ae->term < me->current_term)
    {
        __log(me_, "AE term is less than current term");
        r.success = 0;
        goto done;
    }
    
    // TODO! Need some kind of duplicate detection so we don't apply the same
    // entry more than once (if master sends two identical appendentries
    // messages before getting the first response
    // but we don't want to compromise the need for the master to overwrite
    // the log entries of the follower
    
#if 0
    if (-1 != ae->prev_log_idx &&
        ae->prev_log_idx < raft_get_current_idx(me_))
    {
        __log(me_, "AE prev_idx is less than current idx");
        r.success = 0;
        goto done;
    }
#endif
    
    /* not the first appendentries we've received */
    if (-1 != ae->prev_log_idx)
    {
        raft_entry_t* e;
        
        if ((e = raft_get_entry_from_idx(me_, ae->prev_log_idx)))
        {
            /* 2. Reply false if log doesnt contain an entry at prevLogIndex
             whose term matches prevLogTerm (§5.3) */
            if (e->term != ae->prev_log_term)
            {
                __log(me_, "AE term doesn't match prev_idx");
                r.success = 0;
                goto done;
            }
            
            /* 3. If an existing entry conflicts with a new one (same index
             but different terms), delete the existing entry and all that
             follow it (§5.3) */
            raft_entry_t* e2;
            if ((e2 = raft_get_entry_from_idx(me_, ae->prev_log_idx+1)))
            {
                if (e2->term != ae->term)
                    log_delete(me->log, ae->prev_log_idx+1);
            }
        }
        else
        {
            __log(me_, "AE no log at prev_idx");
            r.success = 0;
            goto done;
            //assert(0);
        }
    }
    
    /* 5. If leaderCommit > commitIndex, set commitIndex =
     min(leaderCommit, last log index) */
    int myCommitIndex = raft_get_commit_idx(me_);
    if (myCommitIndex < ae->leader_commit)
    {
        int newCommitIndex = me->current_idx - 1 < ae->leader_commit ?
            me->current_idx - 1 : ae->leader_commit;
        
        if (newCommitIndex > myCommitIndex) {
            raft_set_commit_idx(me_, newCommitIndex);
            while (1 == raft_apply_entry(me_));
        }
    }
    
    if (raft_is_candidate(me_))
        raft_become_follower(me_);
    
    raft_set_current_term(me_, ae->term);
    
    // append all entries to log if we don't have them already
    // NOTE: for now it is always just 1
    msg_entry_t cmd = ae->entry;
    raft_entry_t* c;
    
    if (ae->n_entries == 1) {
        if (raft_get_current_idx(me_) >  ae->prev_log_idx + 1) {
            __log(me_, "AE got duplicate message");
            r.success = 2;
            goto done;
        }
        
        /* TODO: replace malloc with mempoll/arena */
        c = malloc(sizeof(raft_entry_t));
        c->term = me->current_term;
        c->entry = cmd;
        /*c->len = cmd->len;
         c->id = cmd->id;
         c->data = malloc(cmd->len);
         memcpy(c->data, cmd->data, cmd->len);*/
        if (0 == raft_append_entry(me_, c))
        {
            __log(me_, "AE failure; couldn't append entry");
            r.success = 0;
            goto done;
        }
    }
    

    r.success = 1;
    // If n_entries == 1, first_idx == current_idx
    // otherwise first_idx + 1 == current_idx
    r.current_idx = raft_get_current_idx(me_);
    r.first_idx = ae->prev_log_idx + 1;
    
done:
    __log(me_, "SENDING APPENDENTRIES RESPONSE to %d", node);
    __log(me_, "term: %d", r.term);
    __log(me_, "success: %d", r.success);
    __log(me_, "current_idx: %d", r.current_idx);
    __log(me_, "first_idx: %d", r.first_idx);
    if (me->cb.send_appendentries_response)
        me->cb.send_appendentries_response(me_, me->udata, node, &r);
    return 1;
}

int raft_recv_requestvote(raft_server_t* me_, int node, msg_requestvote_t* vr)
{
    raft_server_private_t* me = (void*)me_;
    msg_requestvote_response_t r;
    
    if (raft_get_current_term(me_) < vr->term)
    {
        me->voted_for = -1;
    }
    
    if (vr->term < raft_get_current_term(me_) ||
        /* we've already voted */
        -1 != me->voted_for ||
        /* we have a more up-to-date log */
        vr->last_log_idx < me->current_idx)
    {
        r.vote_granted = 0;
    }
    else
    {
        raft_vote(me_,node);
        r.vote_granted = 1;
    }
    
    __log(me_, "node %d requested vote: %s",
          node, r.vote_granted == 1 ? "granted" : "not granted");
    
    r.term = raft_get_current_term(me_);
    if (me->cb.send_requestvote_response)
        me->cb.send_requestvote_response(me_, me->udata, node, &r);
    
    return 0;
}

int raft_votes_is_majority(const int num_nodes, const int nvotes)
{
    int half;
    
    if (num_nodes < nvotes)
        return 0;
    half = num_nodes / 2;
    return half + 1 <= nvotes;
}

int raft_recv_requestvote_response(raft_server_t* me_, int node,
                                   msg_requestvote_response_t* r)
{
    raft_server_private_t* me = (void*)me_;
    
    __log(me_, "node %d responded to requestvote: %s",
          node, r->vote_granted == 1 ? "granted" : "not granted");
    
    if (raft_is_leader(me_))
        return 0;
    
    assert(node < me->num_nodes);
    
    //    if (r->term != raft_get_current_term(me_))
    //        return 0;
    
    if (1 == r->vote_granted)
    {
        int votes;
        
        me->votes_for_me[node] = 1;
        votes = raft_get_nvotes_for_me(me_);
        __log(me_, "now have %d of %d votes", votes, me->num_nodes);
        if (raft_votes_is_majority(me->num_nodes, votes))
            raft_become_leader(me_);
    }
    
    return 0;
}

int raft_send_entry_response(raft_server_t* me_,
                             int node, int etyid, int was_committed)
{
    raft_server_private_t* me = (void*)me_;
    msg_entry_response_t res;
    
    __log(me_, "send entry response to: %d", node);
    
    res.id = etyid;
    res.was_committed = was_committed;
    if (me->cb.send_entries_response)
        me->cb.send_entries_response(me_, me->udata, node, &res);
    return 0;
}

int raft_recv_entry(raft_server_t* me_, int node, msg_entry_t* e)
{
    raft_server_private_t* me = (void*)me_;
    raft_entry_t ety;
    int res, i;
    
    __log(me_, "RECEVIED ENTRY FROM: %d", node);
    
    ety.term = me->current_term;
    ety.entry = *e;
    ety.num_nodes = 0;
/*    ety.id = e->id;
    ety.data = e->data;
    ety.len = e->len; */
    res = raft_append_entry(me_, &ety);
    // We don't need this because our clients are infused with the raft servers
    //raft_send_entry_response(me_, node, e->id, res);
    for (i=0; i<me->num_nodes; i++)
    {
        if (me->nodeid == i) continue;
        raft_send_appendentries(me_,i);
    }
    
    // Handle case with 1 server
    if (me->num_nodes == 1)
    {
        raft_apply_entry(me_);
    }
    return 0;
}

int raft_send_requestvote(raft_server_t* me_, int node)
{
    raft_server_private_t* me = (void*)me_;
    msg_requestvote_t rv;
    
    __log(me_, "sending requestvote to: %d", node);
    
    rv.term = me->current_term;
    rv.last_log_idx = raft_get_current_idx(me_);
    if (me->cb.send_requestvote)
        me->cb.send_requestvote(me_, me->udata, node, &rv);
    return 1;
}

int raft_append_entry(raft_server_t* me_, raft_entry_t* c)
{
    raft_server_private_t* me = (void*)me_;
    
    if (1 == log_append_entry(me->log,c))
    {
        __log(me_, "appended entry to log: %d", me->current_idx);
        me->current_idx += 1;
        return 1;
    }
    return 0;
}

int raft_apply_entry(raft_server_t* me_)
{
    raft_server_private_t* me = (void*)me_;
    raft_entry_t* e;
    
    if (!(e = log_get_from_idx(me->log, me->last_applied_idx+1)))
        return 0;
    
    __log(me_, "APPLYING LOG: %d", me->last_applied_idx + 1);
    
    me->last_applied_idx++;
    if (me->commit_idx < me->last_applied_idx)
        me->commit_idx = me->last_applied_idx;
    if (me->cb.applylog)
        me->cb.applylog(me_, me->udata, e->entry);
    return 1;
}

void raft_send_appendentries(raft_server_t* me_, int node)
{
    raft_server_private_t* me = (void*)me_;
    
    if (!(me->cb.send_appendentries))
        return;
    
    msg_appendentries_t ae;
    raft_node_t* p = raft_get_node(me_, node);
    
    ae.term = me->current_term;
    ae.leader_id = me->nodeid;
    ae.leader_commit = me->commit_idx;
    int node_next_idx = raft_node_get_next_idx(p);
    ae.prev_log_idx = node_next_idx - 1;
    if (ae.prev_log_idx != -1) {
        raft_entry_t *entry = log_get_from_idx(me->log, ae.prev_log_idx);
        ae.prev_log_term = entry->term;
    }
    else {
        ae.prev_log_term = -1;
    }
    
    if (me->current_idx > node_next_idx) {
        ae.n_entries = 1;
        raft_entry_t *next_entry = log_get_from_idx(me->log, node_next_idx);
        ae.entry = next_entry->entry;
    }
    else {
        ae.n_entries = 0;
    }
    
    // This should not be here, but just making sure id is not wrong
    // REMOVE AFTER TESTING with 1 touch
    if (ae.n_entries == 1) {
        ae.entry.id = 1;
    }
    
    __log(me_, "SENDING APPENDENTRIES TO: %d", node);
    __log(me_, "current_idx %d", me->current_idx);
    __log(me_, "node_next_idx %d", node_next_idx);
    
    __log(me_, "term %d", ae.term);
    __log(me_, "leader_id %d", ae.leader_id);
    __log(me_, "prev_log_idx %d", ae.prev_log_idx);
    __log(me_, "prev_log_term %d", ae.prev_log_term);
    __log(me_, "n_entries %d", ae.n_entries);
    __log(me_, "leader_commit %d", ae.leader_commit);
    
    if (me->cb.send_appendentries)
        me->cb.send_appendentries(me_, me->udata, node, &ae);
}

void raft_send_appendentries_all(raft_server_t* me_)
{
    raft_server_private_t* me = (void*)me_;
    int i;
    
    for (i=0; i<me->num_nodes; i++)
    {
        if (me->nodeid == i) continue;
        raft_send_appendentries(me_, i);
    }
}

void raft_set_configuration(raft_server_t* me_,
                            raft_node_configuration_t* nodes)
{
    raft_server_private_t* me = (void*)me_;
    int num_nodes;
    
    /* TODO: one memory allocation only please */
    for (num_nodes=0; nodes->udata_address; nodes++)
    {
        num_nodes++;
        me->nodes = realloc(me->nodes,sizeof(raft_node_t*) * num_nodes);
        me->num_nodes = num_nodes;
        me->nodes[num_nodes-1] = raft_node_new(nodes->udata_address);
    }
    me->votes_for_me = calloc(num_nodes, sizeof(int));
}

int raft_get_nvotes_for_me(raft_server_t* me_)
{
    raft_server_private_t* me = (void*)me_;
    int i, votes;
    
    for (i=0, votes=0; i<me->num_nodes; i++)
    {
        if (me->nodeid == i) continue;
        if (1 == me->votes_for_me[i])
            votes += 1;
    }
    
    if (me->voted_for == me->nodeid)
        votes += 1;
    
    return votes;
}

void raft_vote(raft_server_t* me_, int node)
{
    raft_server_private_t* me = (void*)me_;
    me->voted_for = node;
}

raft_node_t* raft_get_node(raft_server_t *me_, int nodeid)
{
    raft_server_private_t* me = (void*)me_;
    
    if (nodeid < 0 || me->num_nodes <= nodeid)
        return NULL;
    return me->nodes[nodeid];
}

int raft_is_follower(raft_server_t* me_)
{
    return raft_get_state(me_) == RAFT_STATE_FOLLOWER;
}

int raft_is_leader(raft_server_t* me_)
{
    return raft_get_state(me_) == RAFT_STATE_LEADER;
}

int raft_is_candidate(raft_server_t* me_)
{
    return raft_get_state(me_) == RAFT_STATE_CANDIDATE;
}

/*--------------------------------------------------------------79-characters-*/
