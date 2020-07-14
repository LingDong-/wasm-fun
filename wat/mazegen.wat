;;========================================================;;
;;      MAZE GENERATION WITH HANDWRITTEN WEBASSEMBLY      ;;
;; `mazegen.wat`    Lingdong Huang 2020    Public Domain  ;;
;;========================================================;;
;; Generate mazes with Wilson's algorithm                 ;;
;; (loop-erased random walks)                             ;;
;; https://en.wikipedia.org/wiki/Maze_generation_algorithm;;
;;--------------------------------------------------------;;

(module

  ;; This maze generator uses Wilson's algorithm, which isn't very
  ;; efficient at all, but has the nice property of being unbiased
  ;; (which is one of the motivations to implement it in something
  ;; fast like WebAssembly):
  ;; "... depth-first search is biased toward long corridors, while
  ;;  Kruskal's/Prim's algorithms are biased toward many short dead 
  ;;  ends. Wilson's algorithm, on the other hand, generates an 
  ;;  unbiased sample from the uniform distribution over all mazes, 
  ;;  using loop-erased random walks." -- Wikipedia

  ;; 4 pages = 4 x 64kb = max dimension 512x512 (cell=1 byte)
  (memory $mem 4)

  ;; All intermediate and final data used by the algorithm are stored
  ;; in each cell, which is thriftly encoded by one byte, as follows:
  ;;
  ;; |--- MSB ---
  ;; 7 UNUSED
  ;; 6 (TEMP) WALK: EXIT DIRECTION - or +
  ;; 5 (TEMP) WALK: EXIT DIRECTION x or y
  ;; 4 VISITED?
  ;; 3 LEFT   WALL OPEN?
  ;; 2 BOTTOM WALL OPEN?
  ;; 1 TOP    WALL OPEN?
  ;; 0 RIGHT  WALL OPEN?
  ;; |--- LSB ---


  (global $jsr (mut i32) (i32.const 0x5EED)) ;; shr3 random seed
  (global $w   (mut i32) (i32.const 512   )) ;; width
  (global $h   (mut i32) (i32.const 512   )) ;; height

  ;; shr3 random number generator
  (func $shr3 (result i32)
    (global.set $jsr (i32.xor (global.get $jsr) (i32.shl   (global.get $jsr) (i32.const 17))))
    (global.set $jsr (i32.xor (global.get $jsr) (i32.shr_u (global.get $jsr) (i32.const 13))))
    (global.set $jsr (i32.xor (global.get $jsr) (i32.shl   (global.get $jsr) (i32.const 5 ))))
    (global.get $jsr)
  )
  (func $set_seed (param $seed i32) (global.set $jsr (local.get $seed)))


  ;; get the highest three bits of a cell at given coordinate
  ;; (used by the random walks)
  (func $get_hi3 (param $x i32) (param $y i32) (result i32)
    (i32.and (i32.shr_u (i32.load8_u (i32.add
      (i32.mul (global.get $w) (local.get $y))
      (local.get $x)
    )) (i32.const 5)) (i32.const 0x7))
  )
  ;; get the lowest five bits of a cell at given coordinate
  ;; (used to mark visited cells and walls)
  (func $get_lo5 (param $x i32) (param $y i32) (result i32)
    (i32.and (i32.load8_u (i32.add
      (i32.mul (global.get $w) (local.get $y))
      (local.get $x)
    )) (i32.const 0x1F))
  )
  ;; erase the highest three bits of a cell at given coordinate
  ;; (to clean up the leftovers from the walks)
  (func $clear_hi3 (param $x i32) (param $y i32)
    (local $o i32)
    (local.set $o (i32.add (i32.mul (global.get $w) (local.get $y)) (local.get $x)))
    (i32.store8 (local.get $o)
      (i32.and (i32.load8_u (local.get $o)) (i32.const 0x1F))
    )
  )
  ;; set the highest three bits of a cell at given coordinate
  ;; (used by the random walks)
  (func $set_hi3 (param $x i32) (param $y i32) (param $v i32)
    (local $o i32)
    (local.set $o (i32.add (i32.mul (global.get $w) (local.get $y)) (local.get $x)))
    (i32.store8 (local.get $o)
      (i32.or
        (i32.and (i32.load8_u (local.get $o)) (i32.const 0x1F))
        (i32.shl (local.get $v) (i32.const 5))
      )
    )
  )
  ;; turn on the nth bit of a cell at given coordinate
  ;; (lsb=0,msb=7)
  (func $on_bitn (param $x i32) (param $y i32) (param $n i32)
    (local $o i32)
    (local.set $o (i32.add (i32.mul (global.get $w) (local.get $y)) (local.get $x)))
    (i32.store8 (local.get $o)
      (i32.or (i32.load8_u (local.get $o)) (i32.shl (i32.const 0x1) (local.get $n)))
    )
  )
  ;; read all 8-bits of a cell at given coordinate
  (func $get_cell (param $x i32) (param $y i32) (result i32)
    (i32.load8_u (i32.add
      (i32.mul (global.get $w) (local.get $y))
      (local.get $x)
    ))
  )
  ;; set all 8-bits of a cell at given coordinate
  (func $set_cell (param $x i32) (param $y i32) (param $v i32)
    (i32.store8 (i32.add
      (i32.mul (global.get $w) (local.get $y))
      (local.get $x)
    ) (local.get $v))
  )

  ;; main routine for generating the maze
  ;; params: width, height -> maze dimensions in cells
  (func $generate_maze (param $width i32) (param $height i32)

    ;; local variables
    (local $x  i32) ;; current coordinate
    (local $y  i32) ;; |
    (local $sx i32) ;; start coordinate of the walk
    (local $sy i32) ;; |
    (local $ox i32) ;; last coordinate
    (local $oy i32) ;; |
    (local $r  i32) ;; random number (for walk direction)

    (global.set $w (local.get $width ))
    (global.set $h (local.get $height))
    
    ;; clear the entire matrix (from previous runs)
    (local.set $y (i32.const 0))
    loop $clear_y
      (local.set $x (i32.const 0))
      loop $clear_x
        (call $set_cell (local.get $x) (local.get $y) (i32.const 0))
        (local.set $x (i32.add (local.get $x) (i32.const 1)))
        (br_if $clear_x (i32.lt_u (local.get $x) (global.get $w)))
      end
      (local.set $y (i32.add (local.get $y) (i32.const 1)))
      (br_if $clear_y (i32.lt_u (local.get $y) (global.get $h)))
    end

    ;; starting cell is (0,0) (but any other cell would work too)
    (call $set_cell (i32.const 0) (i32.const 0) (i32.const 8))

    ;; start walking from another unvisited cell
    ;; (again, any cell would work, but (1,0) is picked out of laziness)
    (local.set $sx (i32.const 1))
    (local.set $sy (i32.const 0))
    (local.set $x  (local.get $sx))
    (local.set $y  (local.get $sy))

    loop $walk

      (local.set $ox (local.get $x))
      (local.set $oy (local.get $y))
      loop $dir

        ;; pick a random direction = rand()%4
        (local.set $r (i32.rem_u (call $shr3) (i32.const 4)))
      
        ;; the LSB of the random number determines the axis, x or y
        (if (i32.eqz (i32.and (local.get $r) (i32.const 1))) (then
          ;; the MSB determines direction, - or +
          (local.set $x (i32.add (local.get $x) 
            (i32.sub (i32.and (local.get $r) (i32.const 2)) (i32.const 1))
          ))
        )(else
          (local.set $y (i32.add (local.get $y) 
            (i32.sub (i32.and (local.get $r) (i32.const 2)) (i32.const 1))
          ))
        ))
        ;; illegal moves (out of bounds), retry
        (if (i32.or(i32.or(i32.or
          (i32.lt_s (local.get $x) (i32.const 0)) 
          (i32.lt_s (local.get $y) (i32.const 0)))
          (i32.gt_s (local.get $x) (i32.sub (global.get $w) (i32.const 1))))
          (i32.gt_s (local.get $y) (i32.sub (global.get $h) (i32.const 1))))
        (then
          ;; undo
          (local.set $x (local.get $ox))
          (local.set $y (local.get $oy))
          (br $dir) ;; redo
        ))
      end

      ;; record the walk
      (call $set_hi3 (local.get $ox) (local.get $oy) (local.get $r) )
      ;; Instead of keeping the cells visited by the walk in a stack, and having to 
      ;; detect and remove loops etc., we can simply (and more efficiently) overwrite
      ;; the "exit direction" for each cell, and upon re-tracing the walk when adding
      ;; it to the maze by following these directions, the loops are automatically 
      ;; avoided because of the overwrite. Inspired by
      ;; http://weblog.jamisbuck.org/2011/1/20/maze-generation-wilson-s-algorithm.html


      (if (call $get_lo5 (local.get $x) (local.get $y)) (then
        ;; we've hit a cell that's part of the maze. the walk is done!

        (local.set $ox  (local.get $x)) ;; save the end point of the walk
        (local.set $oy  (local.get $y))

        (local.set $x  (local.get $sx)) ;; go back to the start point
        (local.set $y  (local.get $sy))

        ;; add the walk to the maze
        loop $retrace

          ;; recover the exit direction
          (local.set $r (call $get_hi3 (local.get $x) (local.get $y)) )

          ;; turn on the "visited" bit
          (call $on_bitn (local.get $x) (local.get $y) (i32.const 4))

          ;; break the walls and goto next cell
          ;; notice the vim "HJKL" ordering for walls :)
          (if (i32.eqz (i32.and (local.get $r) (i32.const 1))) (then
            (if (i32.eqz (i32.and (local.get $r) (i32.const 2))) (then
              ;; break left wall of this cell
              (call $on_bitn (local.get $x) (local.get $y) (i32.const 3))
              ;; exit left
              (local.set $x (i32.sub (local.get $x) (i32.const 1)))
              ;; break right wall of next cell
              (call $on_bitn (local.get $x) (local.get $y) (i32.const 0))

            )(else
              ;; break right wall of this cell
              (call $on_bitn (local.get $x) (local.get $y) (i32.const 0))
              ;; exit right
              (local.set $x (i32.add (local.get $x) (i32.const 1)))
              ;; break left wall of next cell
              (call $on_bitn (local.get $x) (local.get $y) (i32.const 3))

            ))
          )(else
            (if (i32.eqz (i32.and (local.get $r) (i32.const 2))) (then
              ;; break top wall of this cell
              (call $on_bitn (local.get $x) (local.get $y) (i32.const 1))
              ;; exit top
              (local.set $y (i32.sub (local.get $y) (i32.const 1)))
              ;; break bottom wall of next cell
              (call $on_bitn (local.get $x) (local.get $y) (i32.const 2))

            )(else
              ;; break bottom wall of this cell
              (call $on_bitn (local.get $x) (local.get $y) (i32.const 2))
              ;; exit bottom
              (local.set $y (i32.add (local.get $y) (i32.const 1)))
              ;; break top wall of next cell
              (call $on_bitn (local.get $x) (local.get $y) (i32.const 1))

            ))
          ))
          ;; check if we've reached the end of the walk
          (if (i32.and
            (i32.eq (local.get $x) (local.get $ox))
            (i32.eq (local.get $y) (local.get $oy))
          )(then)(else
            (br $retrace) ;; haven't reached the end yet, back to looping
          ))
        end

        ;; reset starting point
        (local.set $sx (i32.const -1))
        (local.set $sy (i32.const -1))

        ;; clean up the leftover from the walk for the cells
        ;; and scan for a new starting point
        (local.set $y (i32.const 0))
        loop $clean_y
          (local.set $x (i32.const 0))
          loop $clean_x
            (call $clear_hi3 (local.get $x) (local.get $y))

            ;; check if we still haven't found a new starting point...
            (if (i32.and
              (i32.eq (local.get $sx) (i32.const -1))
              (i32.eq (local.get $sy) (i32.const -1))
            )(then
              ;; ... and if a cell is elligible (unvisited)
              (if (i32.eqz (call $get_lo5 (local.get $x) (local.get $y)))(then
                (local.set $sx (local.get $x))
                (local.set $sy (local.get $y))
              ))
            ))
            (local.set $x (i32.add (local.get $x) (i32.const 1)))
            (br_if $clean_x (i32.lt_u (local.get $x) (global.get $w)))
          end
          (local.set $y (i32.add (local.get $y) (i32.const 1)))
          (br_if $clean_y (i32.lt_u (local.get $y) (global.get $h)))
        end

        ;; check if we've found a new starting point
        (if (i32.and
          (i32.eq (local.get $sx) (i32.const -1))
          (i32.eq (local.get $sy) (i32.const -1))
        )(then)(else
          ;; new starting point found, start over
          (local.set $x (local.get $sx))
          (local.set $y (local.get $sy))
          (local.set $ox (local.get $x))
          (local.set $oy (local.get $y))

          (br $walk)
        ))
        ;; if this point is reached, algorithm is finished,
        ;; function returns.

      )(else ;; haven't hit a cell that's part of the maze
        (br $walk)  ;; keep walking
      ))
      
    end
  )

  ;; exported API's
  (export "generate_maze" (func $generate_maze))
  (export "get_cell"      (func $get_cell     ))
  (export "set_seed"      (func $set_seed     ))
  (export "mem"           (memory $mem        ))
)