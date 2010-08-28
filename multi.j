## multi.j - multiprocessing
##
## higher-level interface:
##
## Worker() - create a new local worker
##
## remote_apply(w, func, args...) -
##     tell a worker to call a function on the given arguments.
##     for now, functions are passed as symbols, e.g. `randn
##     returns a Future.
##
## wait(f) - wait for, then return the value represented by a Future
##
## pmap(pool, func, lst) -
##     call a function on each element of lst (some 1-d thing), in
##     parallel. pool is a list of available Workers.
##
## lower-level interface:
##
## send_msg(socket, x) - send a Julia object through a socket
## recv_msg(socket) - read the next Julia object from a socket

recv_msg(s) = deserialize(s)
send_msg(s, x) = (serialize(s, x); flush(s))

wait_msg(fd) =
    ccall(dlsym(JuliaDLHandle,"jl_wait_msg"), Int32, (Int32,), fd)==0

# todo:
# - recover from i/o errors
# - handle remote execution errors
# - send pings at some interval to detect failed/hung machines
# - asynch i/o with coroutines to overlap computing with communication
# - all-to-all communication

function jl_worker(fd)
    sock = fdio(fd)

    while true
        if !wait_msg(fd)
            break
        end
        (f, args) = recv_msg(sock)
        # handle message
        result = apply(eval(f), args)
        send_msg(sock, result)
    end
end

function start_local_worker()
    fds = Array(Int32, 2)
    ccall(dlsym(libc,"pipe"), Int32, (Ptr{Int32},), fds)
    rdfd = fds[1]
    wrfd = fds[2]

    if fork()==0
        port = Array(Int16, 1)
        port[1] = 9009
        sockfd = ccall(dlsym(JuliaDLHandle,"open_any_tcp_port"), Int32,
                       (Ptr{Int16},), port)
        if sockfd == -1
            error("could not bind socket")
        end
        io = fdio(wrfd)
        write(io, port[1])
        close(io)
        # close stdin; workers will not use it
        ccall(dlsym(libc,"close"), Int32, (Int32,), 0)

        connectfd = ccall(dlsym(libc,"accept"), Int32,
                          (Int32, Ptr{Void}, Ptr{Void}),
                          sockfd, C_NULL, C_NULL)
        jl_worker(connectfd)
        ccall(dlsym(libc,"close"), Int32, (Int32,), connectfd)
        ccall(dlsym(libc,"close"), Int32, (Int32,), sockfd)
        ccall(dlsym(libc,"exit") , Void , (Int32,), 0)
    end
    io = fdio(rdfd)
    port = read(io, Int16)
    close(io)
    #print("started worker on port ", port, "\n")
    port
end

function connect_to_worker(hostname, port)
    fdio(ccall(dlsym(JuliaDLHandle,"connect_to_host"), Int32,
               (Ptr{Uint8}, Int16), hostname, port))
end

struct Worker
    host::String
    port::Int16
    socket::IOStream
    requests::Queue
    busy::Bool
    maxid::Int32
    pending::Int32
    completed::BTree{Int32,Any}

    Worker() = Worker("localhost", start_local_worker())

    function Worker(host, port)
        sock = connect_to_worker(host, port)
        new(host, port, sock, Queue(), false, 0, 0, BTree(Int32,Any))
    end
end

struct Future
    where::Worker
    id::Int32
    done::Bool
    val
end

# todo:
# - remote references (?)

struct LocalProcess
end

# run a task locally with the remote_apply interface
function remote_apply(w::LocalProcess, f, args...)
    return spawn(()->apply(eval(f), args))
end

function remote_apply(w::Worker, f, args...)
    w.maxid += 1
    nid = w.maxid
    if !w.busy
        send_msg(w.socket, (f, args))
        w.pending = nid
        w.busy = true
    else
        enq(w.requests, Pair(nid, (f, args)))
    end
    Future(w, nid, false, ())
end

function wait(f::Future)
    if f.done
        return f.val
    end
    w = f.where
    if has(w.completed,f.id)
        v = w.completed[f.id]
        del(w.completed,f.id)
        f.done = true
        f.val = v
        return v
    end
    while true
        if !w.busy
            error("invalid Future")
        end
        current = w.pending
        result = recv_msg(w.socket)

        if isempty(w.requests)
            w.busy = false
            w.pending = 0
        else
            # handle next request
            p = pop(w.requests)
            # send remote apply message p.b
            send_msg(w.socket, p.b)
            # w.busy = true  # already true
            w.pending = p.a
        end

        if current == f.id
            f.done = true
            f.val = result
            return result
        else
            # store result, allowing out-of-order retrieval
            w.completed[current] = result
        end
    end
end

function pmap_d(wpool, fname, lst)
    # spawn a task to feed work to each worker as it finishes, providing
    # dynamic load-balancing
    idx = 1
    N = length(lst)
    result = Array(Any, N)
    for w = wpool
        spawn(function ()
                while idx <= N
                  todo = idx; idx+=1
                  f = remote_apply(w, fname, lst[todo])
                  result[todo] = wait(f)
                end
              end)
    end
    while idx <= N
        yieldto(scheduler)
    end
    result
end

function pmap_s(wpool, fname, lst)
    # statically-balanced version
    nw = length(wpool)
    fut = { remote_apply(wpool[(i-1)%nw+1], fname, lst[i]) |
           i = 1:length(lst) }
    for i=1:length(fut)
        fut[i] = wait(fut[i])
    end
    fut
end
