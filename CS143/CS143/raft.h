#ifndef RAFT_H_
#define RAFT_H_

/**
 * Copyright (c) 2013, Willem-Hendrik Thiart
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * @file
 * @author Willem Thiart himself@willemthiart.com
 * @version 0.1
 */

typedef struct {
    /* candidate's term */
    uint16_t term;
    
    /* idx of candidate's last log entry */
    uint16_t last_log_idx;
    
    /* term of candidate's last log entry */
    // probably want this for complete correctness...
    //int last_log_term;
    
    // candidate's device UUID that we echo in response if we vote for this candidate
    char uuid[16];

} msg_requestvote_t;

typedef struct {
    /* entry data */
    // TODO! should think of a more abstracted way of doing this...
    float data[2];
} msg_entry_t;

typedef struct {
    /* currentTerm, for candidate to update itself */
    int term;
    
    /* true means candidate received vote */
    // not really used because we ignore further vote requests that term
    int vote_granted;
    
    // the UUID of the candidate we're voting for
    char uuid[16];
} msg_requestvote_response_t;

/* TODO! this is way more than 20 bytes..., how much room do we have? */
typedef struct {
    int term;
    int leader_id;
    int prev_log_idx;
    int prev_log_term;
    
    // this will ALWAYS be 1 because we have small payloads with BLE
    int n_entries;
    msg_entry_t entry;
    int leader_commit;
} msg_appendentries_t;

typedef struct {
    /* currentTerm, for leader to update itself */
    int term;
    
    /* success true if follower contained entry matching
     * prevLogidx and prevLogTerm */
    int success;
    
    /* Non-Raft fields follow: */
    /* Having the following fields allows us to do less book keeping in
     * regards to full fledged RPC */
    /* This is the highest log IDX we've received and appended to our log */
    int current_idx;
    /* The first idx that we received within the appendentries message */
    int first_idx;
} msg_appendentries_response_t;

typedef void* raft_server_t;
typedef void* raft_node_t;

/**
 * @param raft The Raft server making this callback
 * @param node The peer's ID that we are sending this message to
 * @return 0 on error */
typedef int (
*func_send_requestvote_f
)   (
raft_server_t* raft,
int node,
msg_requestvote_t* msg
);

/**
 * @param raft The Raft server making this callback
 * @param node The peer's ID that we are sending this message to
 * @return 0 on error */
typedef int (
*func_send_requestvote_response_f
)   (
raft_server_t* raft,
int node,
msg_requestvote_response_t* msg
);

/**
 * @param raft The Raft server making this callback
 * @param node The peer's ID that we are sending this message to
 * @return 0 on error */
typedef int (
*func_send_appendentries_f
)   (
raft_server_t* raft,
int node,
msg_appendentries_t* msg
);

/**
 * @param raft The Raft server making this callback
 * @param node The peer's ID that we are sending this message to
 * @return 0 on error */
typedef int (
*func_send_appendentries_response_f
)   (
raft_server_t* raft,
int node,
msg_appendentries_response_t* msg
);


/**
 * Apply this log to the state machine
 * @param raft The Raft server making this callback
 * @param entry Entry to be applied to the log
 * @return 0 on error */
typedef int (
*func_applylog_f
)   (
raft_server_t* raft,
msg_entry_t entry
);

typedef int (
*func_startscan_f
)   (
void
);

typedef int (
*func_stopscan_f
)   (
void
);

typedef struct {
    func_send_requestvote_f send_requestvote;
    func_send_requestvote_response_f send_requestvote_response;
    func_send_appendentries_f send_appendentries;
    func_send_appendentries_response_f send_appendentries_response;
    func_applylog_f applylog;
    func_startscan_f startscan;
    func_stopscan_f stopscan;
} raft_cbs_t;

typedef struct {
    /* entry's term */
    unsigned int term;
    /* the underlying entry */
    msg_entry_t entry;
    /* number of nodes that have this entry */
    unsigned int num_nodes;
} raft_entry_t;

/**
 * Initialise a new Raft server
 *
 * @return newly initialised Raft server */
raft_server_t* raft_new(int nodeid);

/**
 * De-Initialise Raft server
 * Free all memory */
void raft_free(raft_server_t* me_);

/**
 * Set callbacks.
 * Callbacks need to be set by the user for CRaft to work.
 *
 * @param funcs Callbacks
 * @param udata The context that we include when making a callback */
void raft_set_callbacks(raft_server_t* me, raft_cbs_t* funcs);

/**
 * Set configuration
 * @param nodes Array of nodes. End of array is marked by NULL entry */
void raft_set_configuration(raft_server_t* me_, int num_nodes);

/**
 * Set election timeout
 * The amount of time that needs to elapse before we assume the leader is down
 * @param msec Election timeout in milliseconds */
void raft_set_election_timeout(raft_server_t* me, int msec);

/**
 * Set request timeout in milliseconds
 * The amount of time before we resend an appendentries message
 * @param msec Request timeout in milliseconds */
void raft_set_request_timeout(raft_server_t* me_, int msec);

/**
 * Process events that are dependent on time passing
 * @param msec_elapsed Time in milliseconds since the last call
 * @return 0 on error */
int raft_periodic(raft_server_t* me, int msec_elapsed);

/**
 * Receive an appendentries message
 * @param node Index of the node who sent us this message
 * @param ae The appendentries message
 * @return 0 on error */
int raft_recv_appendentries(raft_server_t* me, int node,
                            msg_appendentries_t* ae);

/**
 * Receive a response from an appendentries message we sent
 * @param node Index of the node who sent us this message
 * @param r The appendentries response message
 * @return 0 on error */
int raft_recv_appendentries_response(raft_server_t* me_,
                                     int node, msg_appendentries_response_t* r);
/**
 * Receive a requestvote message
 * @param node Index of the node who sent us this message
 * @param vr The requestvote message
 * @return 0 on error */
int raft_recv_requestvote(raft_server_t* me, int node,
                          msg_requestvote_t* vr);

/**
 * Receive a response from a requestvote message we sent
 * @param node Index of the node who sent us this message
 * @param r The requestvote response message
 * @param node The node this response was sent by */
int raft_recv_requestvote_response(raft_server_t* me, int node,
                                   msg_requestvote_response_t* r);

/**
 * Receive an entry message from client.
 * Append the entry to the log
 * Send appendentries to followers
 * @param node Index of the node who sent us this message
 * @param e The entry message */
int raft_recv_entry(raft_server_t* me, int node, msg_entry_t* e);

/**
 * @return the server's node ID */
int raft_get_nodeid(raft_server_t* me_);

/**
 * @return currently configured election timeout in milliseconds */
int raft_get_election_timeout(raft_server_t* me);

/**
 * @return number of nodes that this server has */
int raft_get_num_nodes(raft_server_t* me);

/**
 * @return number of items within log */
int raft_get_log_count(raft_server_t* me);

/**
 * @return current term */
int raft_get_current_term(raft_server_t* me);

/**
 * @return current log index */
int raft_get_current_idx(raft_server_t* me);

/**
 * @return 1 if follower; 0 otherwise */
int raft_is_follower(raft_server_t* me);

/**
 * @return 1 if leader; 0 otherwise */
int raft_is_leader(raft_server_t* me);

/**
 * @return 1 if candidate; 0 otherwise */
int raft_is_candidate(raft_server_t* me);

/**
 * @return currently elapsed timeout in milliseconds */
int raft_get_timeout_elapsed(raft_server_t* me);

/**
 * @return request timeout in milliseconds */
int raft_get_request_timeout(raft_server_t* me_);

/**
 * @return index of last applied entry */
int raft_get_last_applied_idx(raft_server_t* me);

/**
 * @return 1 if node is leader; 0 otherwise */
int raft_node_is_leader(raft_node_t* node);

/**
 * @return the node's next index */
int raft_node_get_next_idx(raft_node_t* node);

/**
 * @param idx The entry's index
 * @return entry from index */
raft_entry_t* raft_get_entry_from_idx(raft_server_t* me_, int idx);

/**
 * @param node The node's index
 * @return node pointed to by node index */
raft_node_t* raft_get_node(raft_server_t *me_, int node);

/**
 * @return number of votes this server has received this election */
int raft_get_nvotes_for_me(raft_server_t* me_);

/**
 * @return node ID of who I voted for */
int raft_get_voted_for(raft_server_t* me);

void raft_become_candidate(raft_server_t* me_);

// should be called when a node disconnects to clear
// its metadata
void raft_clear_node(raft_server_t* me_, int idx);

#endif /* RAFT_H_ */
