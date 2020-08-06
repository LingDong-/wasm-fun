;;========================================================;;
;;     CONTAINER TYPES WITH HANDWRITTEN WEBASSEMBLY       ;;
;; `containers.wat`  Lingdong Huang 2020    Public Domain ;;
;;========================================================;;
;; array<T> + (linked) list<T> + (hash) map<T,T>          ;;
;;--------------------------------------------------------;;

(module

  ;; This file contains implementations for:
  ;;---------------------------------------------------------
  ;; - ARRAYS (prefix: arr_*)
  ;;   Continous, resizable storage for a sequence of values,
  ;;   similar to C++ vector<T>
  ;;
  ;;   +------------------------------+
  ;;   |data|length|elem_size|capacity|
  ;;   +-|----------------------------+
  ;;     |        +---------------------------
  ;;     `------> |elem 0|elem 1|elem 2|......
  ;;              +---------------------------
  ;;---------------------------------------------------------
  ;; - LISTS (prefix: list_*)
  ;;   Doubly linked list, similar to C++ list<T>
  ;;
  ;;   +--------------------------+
  ;;   |head|tail|length|elem_size|
  ;;   +-|----|-------------------+
  ;;     |    `--------------------------------------------.
  ;;     |                .---------.         .-------...  |
  ;;     |         +------|-------+ |  +------|-------+    `-->+--------------+
  ;;     `-------->|prev|next|data| `->|prev|next|data| ...... |prev|next|data|
  ;;               +--------------+    +-|------------+        +-|------------+
  ;;               ^---------------------'              ....-----'
  ;;---------------------------------------------------------
  ;; - MAPS (prefix: map_*)
  ;;   Hash table (separate chaining with linked lists), 
  ;;   similar to C++ map<T,T>.
  ;;
  ;;   Both size of key and size of value can be variable within
  ;;   the same hash table. In otherwords, it maps from any
  ;;   sequence of bytes to another arbitrary sequence of bytes.
  ;;
  ;;   Functions involving keys have two versions, *_i and *_h.
  ;;   _i takes an i32 as key directly (for simple small keys), 
  ;;   while _h versions read the key from the heap given a 
  ;;   pointer and a byte count (for larger keys)
  ;;
  ;;   +-----------+
  ;;   |num_buckets|          ,-------------------------------.
  ;;   |-----------|        +-|----------------------------+  |  +------------------------------+
  ;;   | bucket 0  |------->|next|key_size|key|val_size|val|  `->|next|key_size|key|val_size|val|
  ;;   |-----------|        +------------------------------+     +------------------------------+
  ;;   | bucket 1  |
  ;;   |-----------|        +------------------------------+
  ;;   | bucket 2  |------->|next|key_size|key|val_size|val|
  ;;   |-----------|        +------------------------------+
  ;;   | ......... |
  ;;---------------------------------------------------------



  ;; The container implementations are polymorphic, meaning that
  ;; the elements can be any type, (bytes, ints, floats, structs...)
  ;; However, since WebAssembly does not have a syntax for user
  ;; types/structs, the functions cannot take them as parameters
  ;; and write them into the container for you -- Therefore, 
  ;; functions that're otherwise supposed to write values to 
  ;; containers will return a pointer to the appropriate memory 
  ;; location instead, and user need to supply custom code to do 
  ;; the former. E.g.
  ;; 
  ;; ;; new array with element-size = 4 bytes (e.g. i32)
  ;; (local.set $a (call $arr_new (i32.const 4)))
  ;;
  ;; ;; 'push' adds an element at the end (does not write the 
  ;; ;; actual value, but returns a pointer to the element)
  ;; (local.set $ptr (call $arr_push (local.get $a)))
  ;;
  ;; ;; user writes the value (e.g. 42) given the pointer
  ;; (i32.store (local.get $ptr) (i32.const 42))

  ;; Each container type is documented in more detail near
  ;; respective implementations

  (global $DEFAULT_CAPACITY (mut i32) (i32.const 8))

  ;;========================================================;;
  ;;     BASELINE MALLOC WITH HANDWRITTEN WEBASSEMBLY       ;;
  ;;========================================================;;
  ;; 32-bit implicit-free-list first-fit baseline malloc    ;;
  ;;--------------------------------------------------------;;

  ;; IMPLICIT FREE LIST:
  ;; Worse utilization and throughput than explicit/segregated, but easier
  ;; to implement :P
  ;;
  ;; HEAP LO                                                         HEAP HI
  ;; +---------------------+---------------------+...+---------------------+
  ;; | HDR | PAYLOAD | FTR | HDR | PAYLOAD | FTR |...+ HDR | PAYLOAD | FTR |
  ;; +----------^----------+---------------------+...+---------------------+
  ;;            |_ i.e. user data
  ;;           
  ;; LAYOUT OF A BLOCK:
  ;; Since memory is aligned to multiple of 4 bytes, the last two bits of
  ;; payload_size is redundant. Therefore the last bit of header is used to
  ;; store the is_free flag.
  ;; 
  ;; |---- HEADER (4b)----
  ;; |    ,--payload size (x4)--.     ,-is free?
  ;; | 0b . . . . . . . . . . . . 0  0
  ;; |------ PAYLOAD -----
  ;; |
  ;; |  user data (N x 4b)
  ;; |
  ;; |---- FOOTER (4b)---- (duplicate of header)
  ;; |    ,--payload size (x4)--.     ,-is free?
  ;; | 0b . . . . . . . . . . . . 0  0
  ;; |--------------------
  ;;
  ;; FORMULAS:
  ;; (these formulas are used throughout the code, so they're listed here
  ;; instead of explained each time encountered)
  ;;
  ;; payload_size = block_size - (header_size + footer_size) = block_size - 8
  ;; 
  ;; payload_pointer = header_pointer + header_size = header_pointer + 4
  ;;
  ;; footer_pointer = header_pointer + header_size + payload_size
  ;;                = (header_pointer + payload_size) + 4
  ;;
  ;; next_header_pointer = footer_pointer + footer_size = footer_pointer + 4
  ;;
  ;; prev_footer_pointer = header_pointer - footer_size = header_pointer - 4

  (memory $mem 1)                                ;; start with 1 page (64K)
  (global $max_addr (mut i32) (i32.const 65536)) ;; initial heap size (64K)
  (global $did_init (mut i32) (i32.const 0))     ;; init() called?

  ;; helpers to pack/unpack payload_size/is_free from header/footer
  ;; by masking out bits

  ;; read payload_size from header/footer given pointer to header/footer
  (func $hdr_get_size (param $ptr i32) (result i32)
    (i32.and (i32.load (local.get $ptr)) (i32.const 0xFFFFFFFC))
  )
  ;; read is_free from header/footer
  (func $hdr_get_free (param $ptr i32) (result i32)
    (i32.and (i32.load (local.get $ptr)) (i32.const 0x00000001))
  )
  ;; write payload_size to header/footer
  (func $hdr_set_size (param $ptr i32) (param $n i32) 
    (i32.store (local.get $ptr) (i32.or
      (i32.and (i32.load (local.get $ptr)) (i32.const 0x00000003))
      (local.get $n)
    ))
  )
  ;; write is_free to header/footer
  (func $hdr_set_free (param $ptr i32) (param $n i32)
    (i32.store (local.get $ptr) (i32.or
      (i32.and (i32.load (local.get $ptr)) (i32.const 0xFFFFFFFE))
      (local.get $n)
    ))
  )
  ;; align memory by 4 bytes
  (func $align4 (param $x i32) (result i32)
    (i32.and
      (i32.add (local.get $x) (i32.const 3))
      (i32.const -4)
    )
  )

  ;; initialize heap
  ;; make the whole heap a big free block
  ;; - automatically invoked by first malloc() call
  ;; - can be manually called to nuke the whole heap
  (func $init
    ;; write payload_size to header and footer
    (call $hdr_set_size (i32.const 0) (i32.sub (global.get $max_addr) (i32.const 8)))
    (call $hdr_set_size (i32.sub (global.get $max_addr) (i32.const 4))
      (i32.sub (global.get $max_addr) (i32.const 8))
    )
    ;; write is_free to header and footer
    (call $hdr_set_free (i32.const 0) (i32.const 1))
    (call $hdr_set_free (i32.sub (global.get $max_addr) (i32.const 4)) (i32.const 1))

    ;; set flag to tell malloc() that we've already called init()
    (global.set $did_init (i32.const 1)) 
  )

  ;; extend (grow) the heap (to accomodate more blocks)
  ;; parameter: number of pages (64K) to grow
  ;; - automatically invoked by malloc() when current heap has insufficient free space
  ;; - can be manually called to get more space in advance
  (func $extend (param $n_pages i32)
    (local $n_bytes i32)
    (local $ftr i32)
    (local $prev_ftr i32)
    (local $prev_hdr i32)
    (local $prev_size i32)

    (local.set $prev_ftr (i32.sub (global.get $max_addr) (i32.const 4)) )

    ;; compute number of bytes from page count (1page = 64K = 65536bytes)
    (local.set $n_bytes (i32.mul (local.get $n_pages) (i32.const 65536)))
  
    ;; system call to grow memory (`drop` discards the (useless) return value of memory.grow)
    (drop (memory.grow (local.get $n_pages) ))

    ;; make the newly acquired memory a big free block
    (call $hdr_set_size (global.get $max_addr) (i32.sub (local.get $n_bytes) (i32.const 8)))
    (call $hdr_set_free (global.get $max_addr) (i32.const 1))

    (global.set $max_addr (i32.add (global.get $max_addr) (local.get $n_bytes) ))
    (local.set $ftr (i32.sub (global.get $max_addr) (i32.const 4)))

    (call $hdr_set_size (local.get $ftr)
      (i32.sub (local.get $n_bytes) (i32.const 8))
    )
    (call $hdr_set_free (local.get $ftr) (i32.const 1))

    ;; see if we can join the new block with the last block of the old heap
    (if (i32.eqz (call $hdr_get_free (local.get $prev_ftr)))(then)(else

      ;; the last block is free, join it.
      (local.set $prev_size (call $hdr_get_size (local.get $prev_ftr)))
      (local.set $prev_hdr
        (i32.sub (i32.sub (local.get $prev_ftr) (local.get $prev_size)) (i32.const 4))
      )
      (call $hdr_set_size (local.get $prev_hdr)
        (i32.add (local.get $prev_size) (local.get $n_bytes) )
      )
      (call $hdr_set_size (local.get $ftr)
        (i32.add (local.get $prev_size) (local.get $n_bytes) )
      )
    ))

  )

  ;; find a free block that fit the request number of bytes
  ;; modifies the heap once a candidate is found
  ;; first-fit: not the best policy, but the simplest
  (func $find (param $n_bytes i32) (result i32)
    (local $ptr i32)
    (local $size i32)
    (local $is_free i32)
    (local $pay_ptr i32)
    (local $rest i32)

    ;; loop through all blocks
    (local.set $ptr (i32.const 0))
    loop $search
      ;; we reached the end of heap and haven't found anything, return NULL
      (if (i32.lt_u (local.get $ptr) (global.get $max_addr))(then)(else
        (i32.const 0)
        return
      ))

      ;; read info about current block
      (local.set $size    (call $hdr_get_size (local.get $ptr)))
      (local.set $is_free (call $hdr_get_free (local.get $ptr)))
      (local.set $pay_ptr (i32.add (local.get $ptr) (i32.const 4) ))

      ;; check if the current block is free
      (if (i32.eq (local.get $is_free) (i32.const 1))(then

        ;; it's free, but too small, move on
        (if (i32.gt_u (local.get $n_bytes) (local.get $size))(then
          (local.set $ptr (i32.add (local.get $ptr) (i32.add (local.get $size) (i32.const 8))))
          (br $search)

        ;; it's free, and large enough to be split into two blocks
        )(else(if (i32.lt_u (local.get $n_bytes) (i32.sub (local.get $size) (i32.const 8)))(then
          ;; OLD HEAP
          ;; ...+-------------------------------------------+...
          ;; ...| HDR |              FREE             | FTR |...
          ;; ...+-------------------------------------------+...
          ;; NEW HEAP
          ;; ...+---------------------+---------------------+...
          ;; ...| HDR | ALLOC   | FTR | HDR |  FREE   | FTR |...
          ;; ...+---------------------+---------------------+...

          ;; size of the remaining half
          (local.set $rest (i32.sub (i32.sub (local.get $size) (local.get $n_bytes) ) (i32.const 8)))

          ;; update headers and footers to reflect the change (see FORMULAS)

          (call $hdr_set_size (local.get $ptr) (local.get $n_bytes))
          (call $hdr_set_free (local.get $ptr) (i32.const 0))

          (call $hdr_set_size (i32.add (i32.add (local.get $ptr) (local.get $n_bytes)) (i32.const 4))
            (local.get $n_bytes)
          )
          (call $hdr_set_free (i32.add (i32.add (local.get $ptr) (local.get $n_bytes)) (i32.const 4))
            (i32.const 0)
          )
          (call $hdr_set_size (i32.add (i32.add (local.get $ptr) (local.get $n_bytes)) (i32.const 8))
            (local.get $rest)
          )
          (call $hdr_set_free (i32.add (i32.add (local.get $ptr) (local.get $n_bytes)) (i32.const 8))
            (i32.const 1)
          )
          (call $hdr_set_size (i32.add (i32.add (local.get $ptr) (local.get $size)) (i32.const 4))
            (local.get $rest)
          )

          (local.get $pay_ptr)
          return

        )(else
          ;; the block is free, but not large enough to be split into two blocks 
          ;; we return the whole block as one
          (call $hdr_set_free (local.get $ptr) (i32.const 0))
          (call $hdr_set_free (i32.add (i32.add (local.get $ptr) (local.get $size)) (i32.const 4))
            (i32.const 0)
          )
          (local.get $pay_ptr)
          return
        ))))
      )(else
        ;; the block is not free, we move on to the next block
        (local.set $ptr (i32.add (local.get $ptr) (i32.add (local.get $size) (i32.const 8))))
        (br $search)
      ))
    end

    ;; theoratically we will not reach here
    ;; return NULL
    (i32.const 0)
  )


  ;; malloc - allocate the requested number of bytes on the heap
  ;; returns a pointer to the block of memory allocated
  ;; returns NULL (0) when OOM
  ;; if heap is not large enough, grows it via extend()
  (func $malloc (param $n_bytes i32) (result i32)
    (local $ptr i32)
    (local $n_pages i32)

    ;; call init() if we haven't done so yet
    (if (i32.eqz (global.get $did_init)) (then
      (call $init)
    ))

    ;; payload size is aligned to multiple of 4
    (local.set $n_bytes (call $align4 (local.get $n_bytes)))

    ;; attempt allocation
    (local.set $ptr (call $find (local.get $n_bytes)) )

    ;; NULL -> OOM -> extend heap
    (if (i32.eqz (local.get $ptr))(then
      ;; compute # of pages from # of bytes, rounding up
      (local.set $n_pages
        (i32.div_u 
          (i32.add (local.get $n_bytes) (i32.const 65527) )
          (i32.const 65528)
        )
      )
      (call $extend (local.get $n_pages))

      ;; try again
      (local.set $ptr (call $find (local.get $n_bytes)) )
    ))
    (local.get $ptr)
  )

  ;; free - free an allocated block given a pointer to it
  (func $free (param $ptr i32)
    (local $hdr i32)
    (local $ftr i32)
    (local $size i32)
    (local $prev_hdr i32)
    (local $prev_ftr i32)
    (local $prev_size i32)
    (local $prev_free i32)
    (local $next_hdr i32)
    (local $next_ftr i32)
    (local $next_size i32)
    (local $next_free i32)
    
    ;; step I: mark the block as free

    (local.set $hdr (i32.sub (local.get $ptr) (i32.const 4)))
    (local.set $size (call $hdr_get_size (local.get $hdr)))
    (local.set $ftr (i32.add (i32.add (local.get $hdr) (local.get $size)) (i32.const 4)))

    (call $hdr_set_free (local.get $hdr) (i32.const 1))
    (call $hdr_set_free (local.get $ftr) (i32.const 1))

    ;; step II: try coalasce

    ;; coalasce with previous block

    ;; check that we're not already the first block
    (if (i32.eqz (local.get $hdr)) (then)(else

      ;; read info about previous block
      (local.set $prev_ftr (i32.sub (local.get $hdr) (i32.const 4)))
      (local.set $prev_size (call $hdr_get_size (local.get $prev_ftr)))
      (local.set $prev_hdr 
        (i32.sub (i32.sub (local.get $prev_ftr) (local.get $prev_size)) (i32.const 4))
      )

      ;; check if previous block is free -> merge them
      (if (i32.eqz (call $hdr_get_free (local.get $prev_ftr))) (then) (else
        (local.set $size (i32.add (i32.add (local.get $size) (local.get $prev_size)) (i32.const 8)))
        (call $hdr_set_size (local.get $prev_hdr) (local.get $size))
        (call $hdr_set_size (local.get $ftr) (local.get $size))

        ;; set current header pointer to previous header
        (local.set $hdr (local.get $prev_hdr))
      ))
    ))

    ;; coalasce with next block
  
    (local.set $next_hdr (i32.add (local.get $ftr) (i32.const 4)))

    ;; check that we're not already the last block
    (if (i32.eq (local.get $next_hdr) (global.get $max_addr)) (then)(else
      
      ;; read info about next block
      (local.set $next_size (call $hdr_get_size (local.get $next_hdr)))
      (local.set $next_ftr 
        (i32.add (i32.add (local.get $next_hdr) (local.get $next_size)) (i32.const 4))
      )

      ;; check if next block is free -> merge them
      (if (i32.eqz (call $hdr_get_free (local.get $next_hdr))) (then) (else
        (local.set $size (i32.add (i32.add (local.get $size) (local.get $next_size)) (i32.const 8)))
        (call $hdr_set_size (local.get $hdr) (local.get $size))
        (call $hdr_set_size (local.get $next_ftr) (local.get $size))
      ))

    ))

  )
  ;; copy a block of memory over, from src pointer to dst pointer
  ;; WebAssembly seems to be planning to support memory.copy
  ;; until then, this function uses a loop and i32.store8/load8
  (func $memcpy (param $dst i32) (param $src i32) (param $n_bytes i32)
    (local $ptr i32)
    (local $offset i32)
    (local $data i32)
    (local.set $offset (i32.const 0))

    loop $cpy
      (local.set $data (i32.load8_u (i32.add (local.get $src) (local.get $offset))))
      (i32.store8 (i32.add (local.get $dst) (local.get $offset)) (local.get $data))

      (local.set $offset (i32.add (local.get $offset) (i32.const 1)))
      (br_if $cpy (i32.lt_u (local.get $offset) (local.get $n_bytes)))
    end
  )

  ;; reallocate memory to new size
  ;; currently does not support contraction
  ;; nothing will happen if n_bytes is smaller than current payload size
  (func $realloc (param $ptr i32) (param $n_bytes i32) (result i32)
    (local $hdr i32)
    (local $next_hdr i32)
    (local $next_ftr i32)
    (local $next_size i32)
    (local $ftr i32)
    (local $size i32)
    (local $rest_hdr i32)
    (local $rest_size i32)
    (local $new_ptr i32)

    (local.set $hdr (i32.sub (local.get $ptr) (i32.const 4)))
    (local.set $size (call $hdr_get_size (local.get $hdr)))

    (if (i32.gt_u (local.get $n_bytes) (local.get $size)) (then) (else
      (local.get $ptr)
      return
    ))

    ;; payload size is aligned to multiple of 4
    (local.set $n_bytes (call $align4 (local.get $n_bytes)))

    (local.set $next_hdr (i32.add (i32.add (local.get $hdr) (local.get $size)) (i32.const 8)))

    ;; Method I: try to expand the current block

    ;; check that we're not already the last block
    (if (i32.lt_u (local.get $next_hdr) (global.get $max_addr) )(then
      (if (call $hdr_get_free (local.get $next_hdr)) (then

        (local.set $next_size (call $hdr_get_size (local.get $next_hdr)))
        (local.set $rest_size (i32.sub 
          (local.get $next_size)
          (i32.sub (local.get $n_bytes) (local.get $size))
        ))
        (local.set $next_ftr (i32.add (i32.add (local.get $next_hdr) (local.get $next_size)) (i32.const 4)))

        ;; next block is big enough to be split into two
        (if (i32.gt_s (local.get $rest_size) (i32.const 0) ) (then
          
          (call $hdr_set_size (local.get $hdr) (local.get $n_bytes))
          
          (local.set $ftr (i32.add (i32.add (local.get $hdr) (local.get $n_bytes) ) (i32.const 4)))
          (call $hdr_set_size (local.get $ftr) (local.get $n_bytes))
          (call $hdr_set_free (local.get $ftr) (i32.const 0))

          (local.set $rest_hdr (i32.add (local.get $ftr) (i32.const 4) ))
          (call $hdr_set_size (local.get $rest_hdr) (local.get $rest_size))
          (call $hdr_set_free (local.get $rest_hdr) (i32.const 1))

          (call $hdr_set_size (local.get $next_ftr) (local.get $rest_size))
          (call $hdr_set_free (local.get $next_ftr) (i32.const 1))

          (local.get $ptr)
          return

        ;; next block is not big enough to be split, but is
        ;; big enough to merge with the current one into one
        )(else (if (i32.gt_s (local.get $rest_size) (i32.const -9) ) (then
        
          (local.set $size (i32.add (i32.add (local.get $size) (i32.const 8) ) (local.get $next_size)))
          (call $hdr_set_size (local.get $hdr) (local.get $size))
          (call $hdr_set_size (local.get $next_ftr) (local.get $size))
          (call $hdr_set_free (local.get $next_ftr) (i32.const 0))

          (local.get $ptr)
          return
        ))))

      ))
    ))

    ;; Method II: allocate a new block and copy over

    (local.set $new_ptr (call $malloc (local.get $n_bytes)))
    (call $memcpy (local.get $new_ptr) (local.get $ptr) (local.get $n_bytes))
    (call $free (local.get $ptr))
    (local.get $new_ptr)

  )

  (func $memmove (param $dst i32) (param $src i32) (param $n_bytes i32)
    (local $ptr i32)
    (local $offset i32)
    (local $data i32)
    
    (if (i32.gt_u (local.get $dst) (local.get $src)) (then
      (local.set $offset (i32.sub (local.get $n_bytes) (i32.const 1)))
      loop $cpy_rev
        (local.set $data (i32.load8_u (i32.add (local.get $src) (local.get $offset))))
        (i32.store8 (i32.add (local.get $dst) (local.get $offset)) (local.get $data))

        (local.set $offset (i32.sub (local.get $offset) (i32.const 1)))
        (br_if $cpy_rev (i32.gt_s (local.get $offset) (i32.const -1)))
      end
    
    )(else
      (local.set $offset (i32.const 0))
      loop $cpy
        (local.set $data (i32.load8_u (i32.add (local.get $src) (local.get $offset))))
        (i32.store8 (i32.add (local.get $dst) (local.get $offset)) (local.get $data))

        (local.set $offset (i32.add (local.get $offset) (i32.const 1)))
        (br_if $cpy (i32.lt_u (local.get $offset) (local.get $n_bytes)))
      end
    ))
  )

  ;;------------------------------------------------------------------------------------

  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
  ;;                                  ;;
  ;;                                  ;;
  ;;               ARRAY              ;;
  ;;                                  ;;
  ;;                                  ;;
  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

  ;; Continous, resizable storage for a sequence of values

  ;; struct arr {
  ;;   void* data
  ;;   int length
  ;;   int elem_size
  ;;   int capacity
  ;; }

  ;; (internal) getter/setters for arr struct fields
  
  (func $_arr_set_data (param $ptr i32) (param $data i32)
    (i32.store (local.get $ptr) (local.get $data))
  )
  (func $_arr_set_length (param $ptr i32) (param $length i32)
    (i32.store (i32.add (local.get $ptr) (i32.const 4)) (local.get $length))
  )
  (func $_arr_set_elem_size (param $ptr i32) (param $elem_size i32)
    (i32.store (i32.add (local.get $ptr) (i32.const 8)) (local.get $elem_size))
  )
  (func $_arr_set_capacity (param $ptr i32) (param $capacity i32)
    (i32.store (i32.add (local.get $ptr) (i32.const 12)) (local.get $capacity))
  )
  (func $_arr_get_data (param $ptr i32) (result i32)
    (i32.load (local.get $ptr))
  )
  (func $_arr_get_elem_size (param $ptr i32) (result i32)
    (i32.load (i32.add (local.get $ptr) (i32.const 8)))
  )
  (func $_arr_get_capacity (param $ptr i32) (result i32)
    (i32.load (i32.add (local.get $ptr) (i32.const 12)))
  )

  ;; returns length of an array given an arr pointer
  (func $arr_length (param $ptr i32) (result i32)
    (i32.load (i32.add (local.get $ptr) (i32.const 4)) )
  )

  ;; initialize a new arr, returns a pointer to it
  ;; elem_size: size of each element, in bytes
  (func $arr_new (param $elem_size i32) (result i32)
    (local $ptr i32)
    (local $data i32)
    (local.set $ptr (call $malloc (i32.const 16)))
    (local.set $data (call $malloc (i32.mul (global.get $DEFAULT_CAPACITY) (local.get $elem_size))))
    (call $_arr_set_data (local.get $ptr) (local.get $data))
    (call $_arr_set_length (local.get $ptr) (i32.const 0))
    (call $_arr_set_elem_size (local.get $ptr) (local.get $elem_size))
    (call $_arr_set_capacity (local.get $ptr) (global.get $DEFAULT_CAPACITY))
    (local.get $ptr)
  )

  ;; free allocated memory given an arr pointer
  (func $arr_free (param $a i32)
    (call $free (call $_arr_get_data (local.get $a)))
    (call $free (local.get $a))
  )

  ;; add an element to the end of the array
  ;; does not write the element, instead, returns a pointer
  ;; to the new last element for the user to write at
  (func $arr_push (param $a i32) (result i32)
    (local $length i32)
    (local $capacity i32)
    (local $data i32)
    (local $elem_size i32)

    (local.set $length (call $arr_length (local.get $a)))
    (local.set $capacity (call $_arr_get_capacity (local.get $a)))
    (local.set $data (call $_arr_get_data (local.get $a)))
    (local.set $elem_size (call $_arr_get_elem_size (local.get $a)))

    (if (i32.lt_u (local.get $length) (local.get $capacity) ) (then) (else
      (local.set $capacity (i32.add
        (i32.add (local.get $capacity) (i32.const 1))
        (i32.mul (local.get $capacity) (i32.const 2))
      ))
      (call $_arr_set_capacity (local.get $a) (local.get $capacity))

      (local.set $data 
        (call $realloc (local.get $data) (i32.mul (local.get $elem_size) (local.get $capacity) ))
      )
      (call $_arr_set_data (local.get $a) (local.get $data))
    ))
    (call $_arr_set_length (local.get $a) (i32.add (local.get $length) (i32.const 1)))
    
    (i32.add (local.get $data) (i32.mul (local.get $length) (local.get $elem_size)))
    
  )

  ;; returns a pointer to the ith element of an array
  (func $arr_at (param $a i32) (param $i i32) (result i32)
    (local $data i32)
    (local $elem_size i32)
    (local.set $data (call $_arr_get_data (local.get $a)))
    (local.set $elem_size (call $_arr_get_elem_size (local.get $a)))
    (i32.add (i32.mul (local.get $i) (local.get $elem_size)) (local.get $data))
  )

  ;; remove the ith element of an array
  (func $arr_remove (param $a i32) (param $i i32)
    (local $data i32)
    (local $elem_size i32)
    (local $length i32)
    (local $offset i32)

    (local.set $length (call $arr_length (local.get $a)))
    (local.set $data (call $_arr_get_data (local.get $a)))
    (local.set $elem_size (call $_arr_get_elem_size (local.get $a)))

    (local.set $offset 
      (i32.add (local.get $data) (i32.mul (local.get $i) (local.get $elem_size) ))
    )

    (call $memmove 
      (local.get $offset)
      (i32.add (local.get $offset) (local.get $elem_size))
      (i32.mul (i32.sub (local.get $length) (local.get $i) ) (local.get $elem_size))
    )
    (call $_arr_set_length  (local.get $a) (i32.sub (local.get $length) (i32.const 1) ))
  )

  ;; remove all elements in an array
  (func $arr_clear (param $a i32)
    (local $data i32)
    (local $elem_size i32)
    (local.set $data (call $_arr_get_data (local.get $a)))
    (local.set $elem_size (call $_arr_get_elem_size (local.get $a)))

    (call $free (local.get $data))
    (call $_arr_set_data (local.get $a)
      (call $malloc (i32.mul (local.get $elem_size) (global.get $DEFAULT_CAPACITY)))
    )
    (call $_arr_set_length (local.get $a) (i32.const 0))
    (call $_arr_set_capacity (local.get $a) (global.get $DEFAULT_CAPACITY))
  )

  ;; concatenate (join) two arrays
  ;; the first array will be extended in place, the second will be untouched
  (func $arr_concat (param $a i32) (param $b i32)
    (local $elem_size i32)

    (local $a_data i32)
    (local $a_length i32)
    (local $a_capacity i32)

    (local $b_data i32)
    (local $b_length i32)
    (local $b_capacity i32)

    (local $sum_length i32)

    (local.set $elem_size (call $_arr_get_elem_size (local.get $a)))

    (local.set $a_length (call $arr_length (local.get $a)))
    (local.set $a_data (call $_arr_get_data (local.get $a)))
    (local.set $a_capacity (call $_arr_get_capacity (local.get $a)))

    (local.set $b_length (call $arr_length (local.get $b)))
    (local.set $b_data (call $_arr_get_data (local.get $b)))
    (local.set $b_capacity (call $_arr_get_capacity (local.get $b)))

    (local.set $sum_length (i32.add (local.get $a_length) (local.get $b_length)))

    (if (i32.gt_u 
      (local.get $sum_length)
      (local.get $a_capacity)
    )(then
      (local.set $a_capacity (local.get $sum_length))
      (call $_arr_set_capacity (local.get $a) (local.get $a_capacity))
      (local.set $a_data
        (call $realloc (local.get $a_data) (i32.mul (local.get $elem_size) (local.get $a_capacity)))
      )
      (call $_arr_set_data (local.get $a) (local.get $a_data))
    ))
    (call $memcpy 
      (i32.add (local.get $a_data) (i32.mul (local.get $a_length) (local.get $elem_size)))
      (local.get $b_data)
      (i32.mul (local.get $b_length) (local.get $elem_size))
    )
    (call $_arr_set_length (local.get $a) (local.get $sum_length))
  )

  ;; insert into an array at given index
  ;; does not write the element, instead, returns a pointer
  ;; to the newly inserted slot for user to write at
  (func $arr_insert (param $a i32) (param $i i32) (result i32)
    (local $data i32)
    (local $elem_size i32)
    (local $length i32)
    (local $offset i32)

    (local.set $length (call $arr_length (local.get $a)))
    (local.set $data (call $_arr_get_data (local.get $a)))
    (local.set $elem_size (call $_arr_get_elem_size (local.get $a)))

    (drop (call $arr_push (local.get $a)))

    (local.set $offset 
      (i32.add (local.get $data) (i32.mul (local.get $i) (local.get $elem_size) ))
    )

    (call $memmove
      (i32.add (local.get $offset) (local.get $elem_size))
      (local.get $offset)
      (i32.mul 
        (i32.sub (i32.sub (local.get $length) (i32.const 1)) (local.get $i) ) 
        (local.get $elem_size)
      )
    )

    (local.get $offset)
  
  )

  ;; slice an array, producing a copy of a range of elements 
  ;; i = starting index (inclusive), j = stopping index (exclusive)
  ;; returns pointer to new array
  (func $arr_slice (param $a i32) (param $i i32) (param $j i32) (result i32)
    (local $a_length i32)
    (local $length i32)
    (local $elem_size i32)
    (local $ptr i32)
    (local $data i32)

    (local.set $a_length (call $arr_length (local.get $a)))

    (if (i32.lt_s (local.get $i) (i32.const 0) )(then
      (local.set $i (i32.add (local.get $a_length) (local.get $i)))
    ))
    (if (i32.lt_s (local.get $j) (i32.const 0) )(then
      (local.set $j (i32.add (local.get $a_length) (local.get $j)))
    ))

    (local.set $length (i32.sub (local.get $j) (local.get $i)))
    (local.set $elem_size (call $_arr_get_elem_size (local.get $a)))

    (local.set $ptr (call $malloc (i32.const 16)))
    (local.set $data (call $malloc (i32.mul (local.get $length) (local.get $elem_size))))
    (call $_arr_set_data (local.get $ptr) (local.get $data))
    (call $_arr_set_length (local.get $ptr) (local.get $length))
    (call $_arr_set_elem_size (local.get $ptr) (local.get $elem_size))
    (call $_arr_set_capacity (local.get $ptr) (local.get $length))

    (call $memcpy (local.get $data) 
      (i32.add
        (call $_arr_get_data (local.get $a))
        (i32.mul (local.get $i) (local.get $elem_size))
      )
      (i32.mul (local.get $length) (local.get $elem_size))
    )

    (local.get $ptr)
  )

  ;; reverse the order of elements in an array in-place
  (func $arr_reverse (param $a i32)
    (local $elem_size i32)
    (local $tmp i32)
    (local $stt i32)
    (local $end i32)
    (local.set $elem_size (call $_arr_get_elem_size (local.get $a)))

    (local.set $stt (call $_arr_get_data (local.get $a)))
    (local.set $end (i32.add 
      (local.get $stt) 
      (i32.mul (local.get $elem_size) (i32.sub (call $arr_length (local.get $a)) (i32.const 1) )) 
    ))

    (local.set $tmp (call $malloc (local.get $elem_size)))

    loop $loop_arr_rev
      (if (i32.lt_u (local.get $stt) (local.get $end)) (then

        (call $memcpy (local.get $tmp) (local.get $stt) (local.get $elem_size))
        (call $memcpy (local.get $stt) (local.get $end) (local.get $elem_size))
        (call $memcpy (local.get $end) (local.get $tmp) (local.get $elem_size))

        (local.set $stt (i32.add (local.get $stt) (local.get $elem_size)))
        (local.set $end (i32.sub (local.get $end) (local.get $elem_size)))

      (br $loop_arr_rev)
      ))
    end

    (call $free (local.get $tmp))
  
  )

  ;;------------------------------------------------------------------------------------

  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
  ;;                                  ;;
  ;;                                  ;;
  ;;               LIST               ;;
  ;;                                  ;;
  ;;                                  ;;
  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

  ;; Doubly linked list

  ;; For users, list element operation always deal with pointers to the
  ;; actual data portion of each node, so they can conveniently write at the
  ;; pointer returned. Internally however, the data field is preceded
  ;; by `prev` and `next` fields, and node pointers points to the beginning of
  ;; the node struct instead. Upon returning values to the user, the offset is
  ;; added.

  ;; struct list {
  ;;   listnode* head
  ;;   listnode* tail
  ;;   int length
  ;;   int elem_size
  ;; }

  ;; (internal) getters and setters for list struct fields

  (func $_list_set_head (param $ptr i32) (param $head i32)
    (i32.store (local.get $ptr) (local.get $head))
  )
  (func $_list_set_tail (param $ptr i32) (param $tail i32)
    (i32.store (i32.add (local.get $ptr) (i32.const 4)) (local.get $tail))
  )
  (func $_list_set_length (param $ptr i32) (param $length i32)
    (i32.store (i32.add (local.get $ptr) (i32.const 8)) (local.get $length))
  )
  (func $_list_set_elem_size (param $ptr i32) (param $elem_size i32)
    (i32.store (i32.add (local.get $ptr) (i32.const 12)) (local.get $elem_size))
  )
  (func $_list_get_head (param $ptr i32) (result i32)
    (i32.load (local.get $ptr))
  )
  (func $_list_get_tail (param $ptr i32) (result i32)
    (i32.load (i32.add (local.get $ptr) (i32.const 4)) )
  )
  (func $list_length (param $ptr i32) (result i32)
    (i32.load (i32.add (local.get $ptr) (i32.const 8)) )
  )
  (func $_list_get_elem_size (param $ptr i32) (result i32)
    (i32.load (i32.add (local.get $ptr) (i32.const 12)))
  )

  ;; get pointer to head of the list
  (func $list_head (param $ptr i32) (result i32)
    (local.set $ptr (i32.load (local.get $ptr)))
    (if (i32.eqz (local.get $ptr))(then
      (i32.const 0)
      return
    ))
    (i32.add (local.get $ptr) (i32.const 8))
  )
  ;; get pointer to tail of the list
  (func $list_tail (param $ptr i32) (result i32)
    (local.set $ptr (i32.load (i32.add (local.get $ptr) (i32.const 4)) ))
    (if (i32.eqz (local.get $ptr))(then
      (i32.const 0)
      return
    ))
    (i32.add (local.get $ptr) (i32.const 8))
  )

  ;; struct listnode {
  ;;   listnode* prev
  ;;   listnode* next
  ;;   data_t data
  ;; }
  
  ;; (internal) getters and setters for list struct fields

  (func $_listnode_set_prev (param $ptr i32) (param $prev i32)
    (i32.store (local.get $ptr) (local.get $prev))
  )
  (func $_listnode_set_next (param $ptr i32) (param $next i32)
    (i32.store (i32.add (local.get $ptr) (i32.const 4)) (local.get $next))
  )
  (func $_listnode_get_prev (param $ptr i32) (result i32)
    (i32.load (local.get $ptr))
  )
  (func $_listnode_get_next (param $ptr i32) (result i32)
    (i32.load (i32.add (local.get $ptr) (i32.const 4)) )
  )

  ;; get pointer to previous element
  (func $list_prev (param $ptr i32) (result i32)
    (local.set $ptr (i32.load (i32.sub (local.get $ptr) (i32.const 8))))
    (if (i32.eqz (local.get $ptr))(then
      (i32.const 0)
      return
    ))
    (i32.add (local.get $ptr) (i32.const 8))
  )

  ;; get pointer to next element
  (func $list_next (param $ptr i32) (result i32)
    (local.set $ptr (i32.load (i32.sub (local.get $ptr) (i32.const 4))))
    (if (i32.eqz (local.get $ptr))(then
      (i32.const 0)
      return
    ))
    (i32.add (local.get $ptr) (i32.const 8))
  )

  ;; initializes a new list, and returns a pointer to it
  ;; elem_size: size of each element, in bytes
  (func $list_new (param $elem_size i32) (result i32)
    (local $ptr i32)
    (local.set $ptr (call $malloc (i32.const 16)))

    (call $_list_set_head      (local.get $ptr) (i32.const 0))
    (call $_list_set_tail      (local.get $ptr) (i32.const 0))
    (call $_list_set_elem_size (local.get $ptr) (local.get $elem_size))
    (call $_list_set_length    (local.get $ptr) (i32.const 0))
    (local.get $ptr)
  )

  ;; add an element to the end of the list
  ;; does not write the element, instead, returns a pointer
  ;; to the new last element for the user to write at
  (func $list_push (param $l i32) (result i32)
    (local $node i32)
    (local $tail i32)

    (local.set $tail (call $_list_get_tail (local.get $l)))
    (local.set $node (call $malloc (i32.add (call $_list_get_elem_size (local.get $l)) (i32.const 8))))

    (call $_listnode_set_prev (local.get $node) (local.get $tail))
    (call $_listnode_set_next (local.get $node) (i32.const 0))

    (if (i32.eqz (call $_list_get_head (local.get $l)))(then
      (call $_list_set_head (local.get $l) (local.get $node))
    )(else
      (call $_listnode_set_next (local.get $tail) (local.get $node))
    ))
    (call $_list_set_tail   (local.get $l) (local.get $node))
    (call $_list_set_length (local.get $l) (i32.add (call $list_length (local.get $l)) (i32.const 1)))

    (i32.add (local.get $node) (i32.const 8))
  )

  ;; insert an element before (left of) a given element
  ;; does not write the element, instead, returns a pointer
  ;; to the new slot for the user to write at
  (func $list_insert_l (param $l i32) (param $iter i32) (result i32)
    (local $next i32)
    (local $prev i32)
    (local $node i32)

    (if (i32.eqz (call $_list_get_head (local.get $l))) (then
      (call $list_push (local.get $l))
      return
    ))

    (local.set $next (i32.sub (local.get $iter) (i32.const 8)))
    (local.set $prev (call $_listnode_get_prev (local.get $next)))

    (local.set $node (call $malloc (i32.add (call $_list_get_elem_size (local.get $l)) (i32.const 8))))

    (if (i32.eqz (local.get $prev)) (then
      (call $_list_set_head (local.get $l) (local.get $node))
      (call $_listnode_set_prev (local.get $node) (i32.const 0))
    )(else
      (call $_listnode_set_next (local.get $prev) (local.get $node))
      (call $_listnode_set_prev (local.get $node) (local.get $prev))
    ))
    (call $_listnode_set_next (local.get $node) (local.get $next))
    (call $_listnode_set_prev (local.get $next) (local.get $node))

    (call $_list_set_length (local.get $l) (i32.add (call $list_length (local.get $l)) (i32.const 1)))
    (i32.add (local.get $node) (i32.const 8))
  )

  ;; insert an element after (right of) a given element
  ;; does not write the element, instead, returns a pointer
  ;; to the new slot for the user to write at
  (func $list_insert_r (param $l i32) (param $iter i32) (result i32)
    (local $next i32)
    (local $prev i32)

    (if (i32.eqz (call $_list_get_head (local.get $l))) (then
      (call $list_push (local.get $l))
      return
    ))

    (local.set $prev (i32.sub (local.get $iter) (i32.const 8)))
    (local.set $next (call $_listnode_get_next (local.get $prev)))

    (if (i32.eqz (local.get $next)) (then
      (call $list_push (local.get $l))
      return
    ))

    (call $list_insert_l (local.get $l) (i32.add (local.get $next) (i32.const 8)))
  )

  ;; remove an element from the list, given the list and the pointer to the element
  (func $list_remove (param $l i32) (param $iter i32)
    (local $next i32)
    (local $prev i32)
    (local $node i32)
    (local.set $node (i32.sub (local.get $iter) (i32.const 8)))
    (local.set $prev (call $_listnode_get_prev (local.get $node)))
    (local.set $next (call $_listnode_get_next (local.get $node)))

    (call $_list_set_length (local.get $l) (i32.sub (call $list_length (local.get $l)) (i32.const 1) ))
    (call $free (local.get $node))

    (if (i32.eqz (local.get $prev)) (then
      (call $_listnode_set_prev (local.get $next) (i32.const 0))
      (call $_list_set_head (local.get $l) (local.get $next))
      return
    ))
    (if (i32.eqz (local.get $next)) (then
      (call $_listnode_set_next (local.get $prev) (i32.const 0))
      (call $_list_set_tail (local.get $l) (local.get $prev))
      return
    ))

    (call $_listnode_set_prev (local.get $next) (local.get $prev))
    (call $_listnode_set_next (local.get $prev) (local.get $next))

  )

  ;; concatenate (join) two lists
  ;; the first array will be extended in place, the second will be *destroyed* and *freed*
  (func $list_concat (param $l0 i32) (param $l1 i32)
    (if (i32.eqz (call $_list_get_head (local.get $l0))) (then
      (call $_list_set_head (local.get $l0) (call $_list_get_head (local.get $l1)))
      (call $_list_set_tail (local.get $l0) (call $_list_get_tail (local.get $l1)))
      (call $free (local.get $l1))
      return
    ))
    (if (i32.eqz (call $_list_get_head (local.get $l1))) (then
      (call $free (local.get $l1))
      return
    ))
    (call $_listnode_set_next (call $_list_get_tail (local.get $l0)) (call $_list_get_head (local.get $l1)))
    (call $_listnode_set_prev (call $_list_get_head (local.get $l1)) (call $_list_get_tail (local.get $l0)))

    (call $_list_set_tail (local.get $l0) (call $_list_get_tail (local.get $l1)))

    (call $_list_set_length (local.get $l0) 
      (i32.add (call $list_length (local.get $l0)) (call $list_length (local.get $l1)))
    )

    (call $free (local.get $l1))
  )

  ;; remove all elements in a list
  (func $list_clear (param $l i32)
    (local $node i32)
    (local $next i32)
    (local.set $node (call $_list_get_head (local.get $l)))
    loop $loop_list_clear
      (if (i32.eqz (local.get $node))(then)(else
        (local.set $next (call $_listnode_get_next (local.get $node)))
        (call $free (local.get $node))
        (local.set $node (local.get $next))
        (br $loop_list_clear)
      ))
    end
    (call $_list_set_head (local.get $l) (i32.const 0))
    (call $_list_set_tail (local.get $l) (i32.const 0))
    (call $_list_set_length (local.get $l) (i32.const 0))
  )

  ;; free allocated memory given a list pointer
  (func $list_free (param $l i32)
    (call $list_clear (local.get $l))
    (call $free (local.get $l))
  )

  ;; reverse the order of elements in a list in-place
  (func $list_reverse (param $l i32)
    (local $node i32)
    (local $temp i32)
    (local.set $temp (i32.const 0))
    (local.set $node (call $_list_get_head (local.get $l)))

    (call $_list_set_head (local.get $l) (call $_list_get_tail (local.get $l)))
    (call $_list_set_tail (local.get $l) (local.get $node))

    loop $loop_list_reverse
      (if (i32.eqz (local.get $node))(then)(else
        (local.set $temp (call $_listnode_get_prev (local.get $node)))
        (call $_listnode_set_prev (local.get $node) (call $_listnode_get_next (local.get $node)) )
        (call $_listnode_set_next (local.get $node) (local.get $temp))
        (local.set $node (call $_listnode_get_prev (local.get $node)))
        (br $loop_list_reverse)
      ))
    end
  )

  ;;------------------------------------------------------------------------------------

  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
  ;;                                  ;;
  ;;                                  ;;
  ;;                MAP               ;;
  ;;                                  ;;
  ;;                                  ;;
  ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

  ;; Hash table (separate chaining with linked lists)

  ;; Both size of key and size of value can be variable within
  ;; the same hash table. In otherwords, it maps from any
  ;; sequence of bytes to another arbitrary sequence of bytes.
  
  ;; Functions involving keys have two versions, *_i and *_h.
  ;; _i takes an i32 as key directly (for simple small keys), 
  ;; while _h versions read the key from the heap given a 
  ;; pointer and a byte count (for larger keys)


  ;; struct map{
  ;;   int num_buckets;
  ;;   mapnode* bucket0;
  ;;   mapnode* bucket1;
  ;;   mapnode* bucket2;
  ;;   ...
  ;; }
  ;; struct mapnode{
  ;;   mapnode* next;
  ;;   int key_size;
  ;;   key_t key;
  ;;   int val_size;
  ;;   val_t val;
  ;; }

  ;; (internal) getters and setters for map struct

  (func $_map_get_num_buckets (param $m i32) (result i32)
    (i32.load (local.get $m))
  )
  (func $_map_set_num_buckets (param $m i32) (param $num_buckets i32)
    (i32.store (local.get $m) (local.get $num_buckets))
  )
  (func $_map_get_bucket (param $m i32) (param $i i32) (result i32)
    (i32.load (i32.add 
      (i32.add (local.get $m) (i32.const 4)) 
      (i32.mul (local.get $i) (i32.const 4))
    ))
  )
  (func $_map_set_bucket (param $m i32) (param $i i32) (param $ptr i32)
    (i32.store (i32.add 
      (i32.add (local.get $m) (i32.const 4)) 
      (i32.mul (local.get $i) (i32.const 4))
    ) (local.get $ptr) )
  )

  ;; (internal) getters and setters for map node struct

  (func $_mapnode_get_next (param $m i32) (result i32)
    (i32.load (local.get $m))
  )
  (func $_mapnode_get_key_size (param $m i32) (result i32)
    (i32.load (i32.add (local.get $m) (i32.const 4)))
  )
  (func $_mapnode_get_key_ptr (param $m i32) (result i32)
    (i32.add (local.get $m) (i32.const 8))
  )
  (func $_mapnode_get_val_size (param $m i32) (result i32)
    (local $key_size i32)
    (local.set $key_size (call $_mapnode_get_key_size (local.get $m)))
    (i32.load (i32.add (i32.add (local.get $m) (i32.const 8)) (local.get $key_size)) )
  )
  (func $_mapnode_get_val_ptr (param $m i32) (result i32)
    (local $key_size i32)

    (local.set $key_size (call $_mapnode_get_key_size (local.get $m)))
    (i32.add (i32.add (local.get $m) (i32.const 12)) (local.get $key_size))
  )
  
  (func $_mapnode_set_next (param $m i32) (param $v i32)
    (i32.store (local.get $m) (local.get $v))
  )
  (func $_mapnode_set_key_size (param $m i32) (param $v i32)
    (i32.store (i32.add (local.get $m) (i32.const 4)) (local.get $v))
  )
  (func $_mapnode_set_val_size (param $m i32) (param $v i32)
    (local $key_size i32)
    (local.set $key_size (call $_mapnode_get_key_size (local.get $m)))
    (i32.store (i32.add (i32.add (local.get $m) (i32.const 8)) (local.get $key_size)) (local.get $v))
  )

  (func $_mapnode_set_key_h (param $m i32) (param $key_ptr i32) (param $key_size i32)
    (local $ptr i32)
    (local $i i32)
    (local.set $ptr (call $_mapnode_get_key_ptr (local.get $m)))
    loop $loop_mapnode_set_key_h
      (i32.store8 
        (i32.add (local.get $ptr) (local.get $i))
        (i32.load8_u (i32.add (local.get $key_ptr) (local.get $i)))
      )
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $loop_mapnode_set_key_h (i32.lt_u (local.get $i) (local.get $key_size) ))
    end
  )
  (func $_mapnode_set_key_i (param $m i32) (param $key i32)
    (i32.store
      (call $_mapnode_get_key_ptr (local.get $m))
      (local.get $key) 
    )
  )

  ;; Hash functions

  ;; hash an integer with SHR3
  (func $_map_hash_i (param $num_buckets i32) (param $key i32) (result i32)
    (local.set $key (i32.xor (local.get $key) (i32.shl   (local.get $key) (i32.const 17))))
    (local.set $key (i32.xor (local.get $key) (i32.shr_u (local.get $key) (i32.const 13))))
    (local.set $key (i32.xor (local.get $key) (i32.shl   (local.get $key) (i32.const 5 ))))
    (i32.rem_u (local.get $key) (local.get $num_buckets))
  )

  ;; hash a sequence of bytes by xor'ing them into an integer and calling _map_hash_i
  (func $_map_hash_h (param $num_buckets i32) (param $key_ptr i32) (param $key_size i32) (result i32)
    (local $key i32)
    (local $i i32)
    (local $byte i32)

    (local.set $i (i32.const 0))
    loop $loop_map_hash_h
      (local.set $byte (i32.load8_u (i32.add (local.get $key_ptr) (local.get $i))))
      
      (local.set $key
        (i32.xor (local.get $key) 
          (i32.shl (local.get $byte) (i32.mul (i32.const 8) (i32.rem_u (local.get $i) (i32.const 4))))
        )
      )
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $loop_map_hash_h (i32.lt_u (local.get $i) (local.get $key_size) ))
    end

    (call $_map_hash_i (local.get $num_buckets) (local.get $key))
  )

  ;; initialize a new map, given number of buckets
  ;; returns a pointer to the map
  (func $map_new (param $num_buckets i32) (result i32)
    (local $m i32)
    (local $i i32)
    (local.set $m (call $malloc (i32.add (i32.mul (local.get $num_buckets) (i32.const 4)) (i32.const 4)) ))
    (call $_map_set_num_buckets (local.get $m) (local.get $num_buckets))

    (local.set $i (i32.const 0))
    loop $loop_map_new_clear
      (call $_map_set_bucket (local.get $m) (local.get $i) (i32.const 0))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $loop_map_new_clear (i32.lt_u (local.get $i) (local.get $num_buckets) ))
    end
    (local.get $m)
  )

  ;; compare the key stored in a node agianst a key on the heap
  (func $_map_cmp_key_h (param $node i32) (param $key_ptr i32) (param $key_size i32) (result i32)
    (local $key_ptr0 i32)
    (local $key_size0 i32)
    (local $i i32)
    (local.set $key_ptr0 (call $_mapnode_get_key_ptr (local.get $node)))
    (local.set $key_size0 (call $_mapnode_get_key_size (local.get $node)))
    (if (i32.eq (local.get $key_size0) (local.get $key_size))(then
      (local.set $i (i32.const 0))
      loop $loop_map_cmp_key_h

        (if (i32.eq 
          (i32.load8_u (i32.add (local.get $key_ptr0) (local.get $i)))
          (i32.load8_u (i32.add (local.get $key_ptr ) (local.get $i)))
        )(then)(else
          (i32.const 0)
          return
        ))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br_if $loop_map_cmp_key_h (i32.lt_u (local.get $i) (local.get $key_size) ))
      end
      (i32.const 1)
      return
    ))
    (i32.const 0)
    return
  )
  
  ;; compare the key stored in a node agianst a key passed directly as i32 argument
  (func $_map_cmp_key_i (param $node i32) (param $key i32) (result i32)
    (local $key_ptr0 i32)
    (local $key_size0 i32)
    (local.set $key_ptr0 (call $_mapnode_get_key_ptr (local.get $node)))
    (local.set $key_size0 (call $_mapnode_get_key_size (local.get $node)))

    (if (i32.eq (local.get $key_size0) (i32.const 4))(then
      (i32.eq (i32.load (local.get $key_ptr0))  (local.get $key) )
      return
    ))
    (i32.const 0)
    return
  )

  ;; insert a new entry to the map, taking a key stored on the heap
  ;; m : the map
  ;; key_ptr: pointer to the key on the heap
  ;; key_size: size of the key in bytes
  ;; val_size: size of the value in bytes
  ;; returns pointer to the value inserted in the map for the user to write at

  (func $map_set_h (param $m i32) (param $key_ptr i32) (param $key_size i32) (param $val_size i32) (result i32)
    (local $num_buckets i32)
    (local $hash i32)
    (local $it i32)
    (local $node_size i32)
    (local $prev i32)

    (local.set $num_buckets (call $_map_get_num_buckets (local.get $m)))
    (local.set $hash (call $_map_hash_h (local.get $num_buckets) (local.get $key_ptr) (local.get $key_size)))
    
    (local.set $it (call $_map_get_bucket (local.get $m) (local.get $hash)))
    (local.set $node_size (i32.add (i32.add (local.get $key_size) (local.get $val_size)) (i32.const 12) ))


    (if (i32.eqz (local.get $it))(then
      (local.set $it (call $malloc (local.get $node_size)))

      (call $_mapnode_set_key_size (local.get $it) (local.get $key_size))
      (call $_mapnode_set_val_size (local.get $it) (local.get $val_size))
      (call $_mapnode_set_next (local.get $it) (i32.const 0))
      (call $_mapnode_set_key_h (local.get $it) (local.get $key_ptr) (local.get $key_size))

      (call $_map_set_bucket (local.get $m) (local.get $hash) (local.get $it))
  
      (call $_mapnode_get_val_ptr (local.get $it))
      return
    )(else
      (local.set $prev (i32.const 0))
      loop $loop_map_set_h
        (if (i32.eqz (local.get $it))(then)(else
          (if (call $_map_cmp_key_h (local.get $it) (local.get $key_ptr) (local.get $key_size) )(then
            (local.set $it (call $realloc (local.get $it) (local.get $node_size)))
            (call $_mapnode_set_val_size (local.get $it) (local.get $val_size))

            (if (i32.eqz (local.get $prev)) (then
              (call $_map_set_bucket (local.get $m) (local.get $hash) (local.get $it))
            )(else
              (call $_mapnode_set_next (local.get $prev) (local.get $it))
            ))
            (call $_mapnode_get_val_ptr (local.get $it))
            return
          ))
          (local.set $prev (local.get $it))
          (local.set $it (call $_mapnode_get_next (local.get $it)))
          (br $loop_map_set_h)
        ))
      end
      (local.set $it (call $malloc (local.get $node_size)))
      (call $_mapnode_set_key_size (local.get $it) (local.get $key_size))
      (call $_mapnode_set_val_size (local.get $it) (local.get $val_size))
      (call $_mapnode_set_next (local.get $it) (i32.const 0))
      (call $_mapnode_set_key_h (local.get $it) (local.get $key_ptr) (local.get $key_size))

      (call $_mapnode_set_next (local.get $prev) (local.get $it))
      (call $_mapnode_get_val_ptr (local.get $it))
      return
    ))
    (i32.const 0)
  )

  ;; insert a new entry to the map, taking a key passed directly as i32 argument
  ;; m : the map
  ;; key: the key
  ;; val_size: size of the value in bytes
  ;; returns pointer to the value inserted in the map for the user to write at

  (func $map_set_i (param $m i32) (param $key i32) (param $val_size i32) (result i32)
    (local $num_buckets i32)
    (local $hash i32)
    (local $it i32)
    (local $node_size i32)
    (local $prev i32)

    (local.set $num_buckets (call $_map_get_num_buckets (local.get $m)))
    (local.set $hash (call $_map_hash_i (local.get $num_buckets) (local.get $key)))
    
    (local.set $it (call $_map_get_bucket (local.get $m) (local.get $hash)))
    (local.set $node_size (i32.add (local.get $val_size) (i32.const 16) ))


    (if (i32.eqz (local.get $it))(then
      (local.set $it (call $malloc (local.get $node_size)))

      (call $_mapnode_set_key_size (local.get $it) (i32.const 4))
      (call $_mapnode_set_val_size (local.get $it) (local.get $val_size))
      (call $_mapnode_set_next (local.get $it) (i32.const 0))
      (call $_mapnode_set_key_i (local.get $it) (local.get $key))

      (call $_map_set_bucket (local.get $m) (local.get $hash) (local.get $it))
  
      (call $_mapnode_get_val_ptr (local.get $it))
      return
    )(else
      (local.set $prev (i32.const 0))
      loop $loop_map_set_i
        (if (i32.eqz (local.get $it))(then)(else
          (if (call $_map_cmp_key_i (local.get $it) (local.get $key) )(then
            (local.set $it (call $realloc (local.get $it) (local.get $node_size)))
            (call $_mapnode_set_val_size (local.get $it) (local.get $val_size))

            (if (i32.eqz (local.get $prev)) (then
              (call $_map_set_bucket (local.get $m) (local.get $hash) (local.get $it))
            )(else
              (call $_mapnode_set_next (local.get $prev) (local.get $it))
            ))
            (call $_mapnode_get_val_ptr (local.get $it))
            return
          ))
          (local.set $prev (local.get $it))
          (local.set $it (call $_mapnode_get_next (local.get $it)))
          (br $loop_map_set_i)
        ))
      end
      (local.set $it (call $malloc (local.get $node_size)))
      (call $_mapnode_set_key_size (local.get $it) (i32.const 4))
      (call $_mapnode_set_val_size (local.get $it) (local.get $val_size))
      (call $_mapnode_set_next (local.get $it) (i32.const 0))
      (call $_mapnode_set_key_i (local.get $it) (local.get $key))

      (call $_mapnode_set_next (local.get $prev) (local.get $it))
      (call $_mapnode_get_val_ptr (local.get $it))
      return
    ))
    (i32.const 0)
  )

  ;; lookup a key for its value in the map, taking a key stored on the heap
  ;; m : the map
  ;; key_ptr: pointer to the key on the heap
  ;; key_size: size of the key in bytes
  ;; returns pointer to the value in the map, NULL (0) if not found.

  (func $map_get_h (param $m i32) (param $key_ptr i32) (param $key_size i32) (result i32)
    (local $num_buckets i32)
    (local $hash i32)
    (local $it i32)

    (local.set $num_buckets (call $_map_get_num_buckets (local.get $m)))
    (local.set $hash (call $_map_hash_h (local.get $num_buckets) (local.get $key_ptr) (local.get $key_size)))
    (local.set $it (call $_map_get_bucket (local.get $m) (local.get $hash)))

    loop $loop_map_get_h
      (if (i32.eqz (local.get $it))(then)(else
        (if (call $_map_cmp_key_h (local.get $it) (local.get $key_ptr) (local.get $key_size) )(then
          (call $_mapnode_get_val_ptr (local.get $it))
          return
        ))
        (local.set $it (call $_mapnode_get_next (local.get $it)))
        (br $loop_map_get_h)
      ))
    end

    (i32.const 0)
  )

  ;; lookup a key for its value in the map, taking a key passed directly as i32 argument
  ;; m : the map
  ;; key : the key
  ;; returns pointer to the value in the map, NULL (0) if not found.

  (func $map_get_i (param $m i32) (param $key i32) (result i32)
    (local $num_buckets i32)
    (local $hash i32)
    (local $it i32)

    (local.set $num_buckets (call $_map_get_num_buckets (local.get $m)))
    (local.set $hash (call $_map_hash_i (local.get $num_buckets) (local.get $key)))
    (local.set $it (call $_map_get_bucket (local.get $m) (local.get $hash)))

    loop $loop_map_get_i
      (if (i32.eqz (local.get $it))(then)(else
        (if (call $_map_cmp_key_i (local.get $it) (local.get $key) )(then
          (call $_mapnode_get_val_ptr (local.get $it))
          return
        ))
        (local.set $it (call $_mapnode_get_next (local.get $it)))
        (br $loop_map_get_i)
      ))
    end

    (i32.const 0)
  )

  ;; remove a key-value pair from the map, given a key stored on the heap
  ;; m : the map
  ;; key_ptr: pointer to the key on the heap
  ;; key_size: size of the key in bytes

  (func $map_remove_h (param $m i32) (param $key_ptr i32) (param $key_size i32)
    (local $num_buckets i32)
    (local $hash i32)
    (local $it i32)
    (local $prev i32)
    (local $next i32)

    (local.set $num_buckets (call $_map_get_num_buckets (local.get $m)))
    (local.set $hash (call $_map_hash_h (local.get $num_buckets) (local.get $key_ptr) (local.get $key_size)))
    (local.set $it (call $_map_get_bucket (local.get $m) (local.get $hash)))
    
    (local.set $prev (i32.const 0))

    loop $loop_map_remove_h
      (if (i32.eqz (local.get $it))(then)(else
        (if (call $_map_cmp_key_h (local.get $it) (local.get $key_ptr) (local.get $key_size) )(then
          (local.set $next (call $_mapnode_get_next (local.get $it)))

          (if (i32.eqz (local.get $prev)) (then
            (call $_map_set_bucket (local.get $m) (local.get $hash) (local.get $next))
          )(else
            (call $_mapnode_set_next (local.get $prev) (local.get $next))
          ))
          (call $free (local.get $it))
          return
        ))
        (local.set $prev (local.get $it))
        (local.set $it (local.get $next))
        (br $loop_map_remove_h)
      ))
    end

  )

  ;; remove a key-value pair from the map, given a key passed directly as i32 argument
  ;; m : the map
  ;; key : the key
  (func $map_remove_i (param $m i32) (param $key i32)
    (local $num_buckets i32)
    (local $hash i32)
    (local $it i32)
    (local $prev i32)
    (local $next i32)

    (local.set $num_buckets (call $_map_get_num_buckets (local.get $m)))
    (local.set $hash (call $_map_hash_i (local.get $num_buckets) (local.get $key)))
    (local.set $it (call $_map_get_bucket (local.get $m) (local.get $hash)))
    
    (local.set $prev (i32.const 0))

    loop $loop_map_remove_i
      (if (i32.eqz (local.get $it))(then)(else
        (if (call $_map_cmp_key_i (local.get $it) (local.get $key) )(then
          (local.set $next (call $_mapnode_get_next (local.get $it)))

          (if (i32.eqz (local.get $prev)) (then
            (call $_map_set_bucket (local.get $m) (local.get $hash) (local.get $next))
          )(else
            (call $_mapnode_set_next (local.get $prev) (local.get $next))
          ))
          (call $free (local.get $it))
          return
        ))
        (local.set $prev (local.get $it))
        (local.set $it (local.get $next))
        (br $loop_map_remove_i)
      ))
    end

  )

  ;; get the size of a value in bytes, given a pointer to the value in the map
  (func $map_val_size (param $val_ptr i32) (result i32)
    (i32.load (i32.sub (local.get $val_ptr) (i32.const 4)))
  )

  ;; generate a new iterator for traversing map pairs
  ;; in effect, this returns a pointer to the first node
  (func $map_iter_new  (param $m i32) (result i32)
    (local $num_buckets i32)
    (local $i i32)
    (local $node i32)

    (local.set $num_buckets (call $_map_get_num_buckets (local.get $m)))

    (local.set $i (i32.const 0))
    loop $loop_map_iter_new
      (local.set $node (call $_map_get_bucket (local.get $m) (local.get $i)))
      (if (i32.eqz (local.get $node))(then)(else
        (local.get $node)
        return
      ))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $loop_map_iter_new (i32.lt_u (local.get $i) (local.get $num_buckets) ))
    end
    (i32.const 0)
    return
  )

  ;; increment an interator for traversing map pairs
  ;; in effect, this finds the next node of a given node, by first looking
  ;; at the linked list, then re-hashing the key to look through the rest of the hash table
  (func $map_iter_next (param $m i32) (param $iter i32) (result i32)
    (local $next i32)
    (local $num_buckets i32)
    (local $node i32)
    (local $i i32)
    
    (local.set $num_buckets (call $_map_get_num_buckets (local.get $m)))

    (local.set $next (call $_mapnode_get_next (local.get $iter)))

    (if (i32.eqz (local.get $next))(then

      (local.set $i (i32.add (call $_map_hash_h
        (local.get $num_buckets)
        (call $_mapnode_get_key_ptr  (local.get $iter))
        (call $_mapnode_get_key_size (local.get $iter))
      ) (i32.const 1)))

      
      (if (i32.eq (local.get $i) (local.get $num_buckets)) (then
        (i32.const 0)
        return
      ))
      
      loop $loop_map_iter_next
        (local.set $node (call $_map_get_bucket (local.get $m) (local.get $i)))
        (if (i32.eqz (local.get $node))(then)(else
          (local.get $node)
          return
        ))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br_if $loop_map_iter_next (i32.lt_u (local.get $i) (local.get $num_buckets) ))
      end

      (i32.const 0)
      return

    )(else
      (local.get $next)
      return
    ))
    (i32.const 0)
    return
  )

  ;; given a map iterator, get a pointer to the key stored
  (func $map_iter_key_h (param $iter i32) (result i32)
    (call $_mapnode_get_key_ptr (local.get $iter))
  )
  ;; given a map iterator, read the key stored as an int
  ;; only works if your key is an i32
  (func $map_iter_key_i (param $iter i32) (result i32)
    (i32.load (call $_mapnode_get_key_ptr (local.get $iter)))
  )
  ;; given a map iterator, get a pointer to the value stored
  (func $map_iter_val (param $iter i32) (result i32)
    (call $_mapnode_get_val_ptr (local.get $iter))
  )

  ;; remove all key-values in the map
  (func $map_clear (param $m i32)
    (local $num_buckets i32)
    (local $hash i32)
    (local $it i32)

    (local $next i32)

    (local.set $num_buckets (call $_map_get_num_buckets (local.get $m)))

    (local.set $hash (i32.const 0))

    loop $loop_map_clear_buckets

      (local.set $it (call $_map_get_bucket (local.get $m) (local.get $hash)))

      loop $loop_map_clear_nodes
        (if (i32.eqz (local.get $it))(then)(else
          (local.set $next (call $_mapnode_get_next (local.get $it)))

          (call $free (local.get $it))

          (local.set $it (local.get $next))
          (br $loop_map_clear_nodes)
        ))
      end

      (call $_map_set_bucket (local.get $m) (local.get $hash) (i32.const 0))

      (local.set $hash (i32.add (local.get $hash) (i32.const 1)))
      (br_if $loop_map_clear_buckets (i32.lt_u (local.get $hash) (local.get $num_buckets)))

    end  
  )

  ;; free all allocated memory for a map
  (func $map_free (param $m i32)
    (call $map_clear (local.get $m))
    (call $free (local.get $m))
  )

  ;; exported API's
  (export "init"    (func   $init   ))
  (export "extend"  (func   $extend ))
  (export "malloc"  (func   $malloc ))
  (export "free"    (func   $free   ))
  (export "mem"     (memory $mem    ))

  (export "arr_length"     (func $arr_length    ))
  (export "arr_new"        (func $arr_new       ))
  (export "arr_free"       (func $arr_free      ))
  (export "arr_push"       (func $arr_push      ))
  (export "arr_at"         (func $arr_at        ))
  (export "arr_remove"     (func $arr_remove    ))
  (export "arr_clear"      (func $arr_clear     ))
  (export "arr_concat"     (func $arr_concat    ))
  (export "arr_insert"     (func $arr_insert    ))
  (export "arr_slice"      (func $arr_slice     ))
  (export "arr_reverse"    (func $arr_reverse   ))

  (export "list_length"    (func $list_length   ))
  (export "list_head"      (func $list_head     ))
  (export "list_tail"      (func $list_tail     ))
  (export "list_prev"      (func $list_prev     ))
  (export "list_next"      (func $list_next     ))
  (export "list_new"       (func $list_new      ))
  (export "list_free"      (func $list_free     ))
  (export "list_push"      (func $list_push     ))
  (export "list_insert_l"  (func $list_insert_l ))
  (export "list_insert_r"  (func $list_insert_r ))
  (export "list_remove"    (func $list_remove   ))
  (export "list_concat"    (func $list_concat   ))
  (export "list_clear"     (func $list_clear    ))
  (export "list_reverse"   (func $list_reverse  ))

  (export "map_new"        (func $map_new       ))
  (export "map_set_h"      (func $map_set_h     ))
  (export "map_get_h"      (func $map_get_h     ))
  (export "map_set_i"      (func $map_set_i     ))
  (export "map_get_i"      (func $map_get_i     ))
  (export "map_remove_h"   (func $map_remove_h  ))
  (export "map_remove_i"   (func $map_remove_i  ))
  (export "map_val_size"   (func $map_val_size  ))
  (export "map_iter_new"   (func $map_iter_new  ))
  (export "map_iter_next"  (func $map_iter_next ))
  (export "map_iter_key_h" (func $map_iter_key_h))
  (export "map_iter_key_i" (func $map_iter_key_i))
  (export "map_iter_val"   (func $map_iter_val  ))
  (export "map_clear"      (func $map_clear     ))
  (export "map_free"       (func $map_free      ))
)
