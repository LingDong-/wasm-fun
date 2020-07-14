;;========================================================;;
;;     CONTOUR TRACING WITH HANDWRITTEN WEBASSEMBLY       ;;
;; `findcontours.wat` Lingdong Huang 2020   Public Domain ;;
;;========================================================;;
;; Finding contours in binary image                       ;;
;; Implements Suzuki-Abe algorithm.                       ;;
;; https://www.academia.edu/15495158/                     ;;
;;--------------------------------------------------------;;


(module

  (memory $mem 48) 

  ;; datastructure
  ;;
  ;; 0--- image section - - - - - (size computed from input size)
  ;; | (i16) 1st pixel data
  ;; | (i16) 2nd pixel data
  ;; |   ...............
  ;; |--- contour info table - - -(fixed size ~ max contours)
  ;; |--- 1st contour
  ;; | (i16) parent (i8) is_hole (i8) unused
  ;; | (i32) absolute memory offset
  ;; | (i32) length         |
  ;; | (i32) unused         |
  ;; |--- 2nd contour       |
  ;; |   ...............    |
  ;; |--- contour data - - -|- - -(grows as needed until OOM)
  ;; |--- 1st contour      \|/
  ;; | (i32) [y0*w+x0] vertex0
  ;; | (i32) [y1*w+x1] vertex1
  ;; | (i32) [y2*w+x2] vertex2
  ;; | (i32)  ... ...
  ;; |--- 2nd contour
  ;; |   ...............
  ;; |---- end


  ;; global variables
  ;; some random defaults to be overwritten by setup()
  (global $w                   (mut i32) (i32.const 512   )) ;; width
  (global $h                   (mut i32) (i32.const 512   )) ;; height
  (global $max_contours        (mut i32) (i32.const 8192  ))
  (global $offset_contour_info (mut i32) (i32.const 524288))
  (global $offset_contour_data (mut i32) (i32.const 557056))

  ;; align memory by 4 bytes (int)
  (func $align4 (param $x i32) (result i32)
    (i32.and
      (i32.add (local.get $x) (i32.const 3))
      (i32.const -4)
    )
  )
  
  ;; setup: specify width, height, and maximum number of contours expected
  (func $setup (param $width i32) (param $height i32) (param $max_cnt i32)
    (global.set $w (local.get $width))
    (global.set $h (local.get $height))
    (global.set $max_contours (local.get $max_cnt))
    (global.set $offset_contour_info (call $align4
      (i32.mul (i32.mul (global.get $w) (global.get $h)) (i32.const 2))
    ))
    (global.set $offset_contour_data (i32.add 
      (i32.mul (global.get $max_contours) (i32.const 4)) 
      (global.get $offset_contour_info)
    ))

  )

  ;; pixels are stored as signed 16-bit row-major array in memory
  ;; get pixel by row # and column #
  (func $get_ij (param $i i32) (param $j i32) (result i32)
    (i32.load16_s (i32.mul (i32.add
      (i32.mul (global.get $w) (local.get $i))
      (local.get $j)) (i32.const 2)
    ))
  )

  ;; set pixel by row # and column #
  (func $set_ij (param $i i32) (param $j i32) (param $v i32)
    (i32.store16 (i32.mul (i32.add
      (i32.mul (global.get $w) (local.get $i))
      (local.get $j)) (i32.const 2)
    ) (local.get $v))
  )

  ;; get pixel by index (pre-computed from row and column)
  (func $get_idx (param $idx i32) (result i32)
    (i32.load16_s (i32.mul (local.get $idx) (i32.const 2)))
  )

  ;; set pixel by index
  (func $set_idx (param $idx i32) (param $v i32)
    (i32.store16 (i32.mul (local.get $idx) (i32.const 2)) (local.get $v))
  )

  ;; get the offset of the header of the nth contour
  (func $get_nth_contour_info (param $n i32) (result i32)
    (i32.add 
      (global.get $offset_contour_info) 
      (i32.mul (local.get $n) (i32.const 16))
    )
  )

  ;; set the header of the nth contour
  (func $set_nth_contour_info (param $n i32) 
    (param $parent  i32)
    (param $is_hole i32)
    (param $offset  i32)
    (param $len     i32)
    (local $o       i32)
    (local.set $o (call $get_nth_contour_info (local.get $n)))
    (i32.store16 (local.get $o) (local.get $parent))
    (i32.store8  (i32.add (local.get $o) (i32.const 2)) (local.get $is_hole))
    (i32.store   (i32.add (local.get $o) (i32.const 4)) (local.get $offset ))
    (i32.store   (i32.add (local.get $o) (i32.const 8)) (local.get $len    ))
  )

  ;; set the length of the nth contour in the header
  ;; this exists in addition to set_nth_contour_info because
  ;; length of the contour changes dynamically unlike the other attributes
  (func $set_nth_contour_length (param $n i32) (param $len i32)
    (i32.store (i32.add 
        (call $get_nth_contour_info (local.get $n))
        (i32.const 8))
      (local.get $len)
    )
  )

  ;; write vertex coordinates at pointer location
  ;; encoded as i*w+j
  (func $write_vertex (param $ptr i32) (param $i i32) (param $j i32)
    (i32.store (local.get $ptr) 
      (i32.add (i32.mul (local.get $i) (global.get $w)) (local.get $j))
    )
  )

  ;; absolute value for i32
  (func $abs_i32 (param $x i32) (result i32)
    (if (i32.lt_s (local.get $x) (i32.const 0))(then
        (i32.sub (i32.const 0) (local.get $x))
        return
    ))
    (local.get $x)
  )

  ;; each neighbor in the moore (8-connected) neighborhood is given an ID
  ;; counter-clockwise for easy access:
  ;; 3 2 1
  ;; 4   0
  ;; 5 6 7

  ;; convert aforementioned neighbor id to index (i*w+j)
  (func $neighbor_id2idx (param $i i32) (param $j i32) (param $id i32) (result i32)
    (local $ii i32)
    (local $jj i32)

    (if (i32.eqz (local.get $id)) (then
      (local.set $ii          (local.get $i)               )
      (local.set $jj (i32.add (local.get $j) (i32.const 1)))

    )(else(if (i32.eq (local.get $id) (i32.const 1)) (then
      (local.set $ii (i32.sub (local.get $i) (i32.const 1)))
      (local.set $jj (i32.add (local.get $j) (i32.const 1)))

    )(else(if (i32.eq (local.get $id) (i32.const 2)) (then
      (local.set $ii (i32.sub (local.get $i) (i32.const 1)))
      (local.set $jj          (local.get $j)               )

    )(else(if (i32.eq (local.get $id) (i32.const 3)) (then
      (local.set $ii (i32.sub (local.get $i) (i32.const 1)))
      (local.set $jj (i32.sub (local.get $j) (i32.const 1)))

    )(else(if (i32.eq (local.get $id) (i32.const 4)) (then
      (local.set $ii          (local.get $i)               )
      (local.set $jj (i32.sub (local.get $j) (i32.const 1)))

    )(else(if (i32.eq (local.get $id) (i32.const 5)) (then
      (local.set $ii (i32.add (local.get $i) (i32.const 1)))
      (local.set $jj (i32.sub (local.get $j) (i32.const 1)))

    )(else(if (i32.eq (local.get $id) (i32.const 6)) (then
      (local.set $ii (i32.add (local.get $i) (i32.const 1)))
      (local.set $jj          (local.get $j)               )

    )(else
      (local.set $ii (i32.add (local.get $i) (i32.const 1)))
      (local.set $jj (i32.add (local.get $j) (i32.const 1)))

    ))))))))))))))

    (i32.add
      (i32.mul (global.get $w) (local.get $ii))
      (local.get $jj)
    )
  )

  ;; get neighbor id from relative position
  ;; i0,j0: current position, i,j: neighbor position
  (func $neighbor_idx2id (param $i0 i32) (param $j0 i32) 
                         (param $i i32) (param $j i32) (result i32)
    (local $di i32)
    (local $dj i32)
    (local $id i32)
    (local.set $di (i32.sub (local.get $i) (local.get $i0)))
    (local.set $dj (i32.sub (local.get $j) (local.get $j0)))

    (if (i32.eq (local.get $di) (i32.const -1)) (then

      (if (i32.eq (local.get $dj) (i32.const -1)) (then
        (local.set $id (i32.const 3))
      )(else(if (i32.eq (local.get $dj) (i32.const 0)) (then
        (local.set $id (i32.const 2))
      )(else
        (local.set $id (i32.const 1))
      ))))

    )(else(if (i32.eq (local.get $di) (i32.const 0)) (then

      (if (i32.eq (local.get $dj) (i32.const -1)) (then
        (local.set $id (i32.const 4))
      )(else
        (local.set $id (i32.const 0))
      ))

    )(else

      (if (i32.eq (local.get $dj) (i32.const -1)) (then
        (local.set $id (i32.const 5))
      )(else(if (i32.eq (local.get $dj) (i32.const 0)) (then
        (local.set $id (i32.const 6))
      )(else
        (local.set $id (i32.const 7))
      ))))

    ))))

    (local.get $id)
  )

  ;; find first non-0 pixel in the neighborhood, clockwise or counter-clockwise as specified
  ;; i0,j0:  current position
  ;; i,j:    position of the first pixel to start searching from
  ;; offset: index offset from the first pixel (e.g. 1 -> start from the second pixel)
  ;; cwccw : -1 for clockwise, +1 for counter-clockwise
  ;; returns computed index if found, -1 if not found
  (func $rot_non0 (param $i0 i32) (param $j0 i32) 
                  (param $i i32) (param $j i32) (param $offset i32) (param $cwccw i32)
                  (result i32)
    (local $id i32)
    (local $k  i32)
    (local $kk i32)
    (local $ij i32)

    (local.set $id (call $neighbor_idx2id (local.get $i0) (local.get $j0) (local.get $i) (local.get $j) ))

    (local.set $k (i32.const 0))
    loop $l0
      (local.set $kk 
        (i32.rem_u
          (i32.add
            (i32.add
              (i32.add (i32.mul (local.get $k) (local.get $cwccw)) (local.get $id)  )
              (local.get $offset)
            )
            (i32.const 16)
          )
          (i32.const 8)
        )
      )
      (local.set $ij 
        (call $neighbor_id2idx (local.get $i0) (local.get $j0) (local.get $kk))
      )
      (if (i32.eqz (call $get_idx (local.get $ij)) ) (then
        ;;pass
      )(else
        (local.get $ij)
        return
      ))

      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      
      (br_if $l0 (i32.lt_u (local.get $k) (i32.const 8)))
    end

    (i32.const -1)
  )

  ;; main function: find contours in the current image
  ;; before calling:
  ;; - use setup()  for initialization
  ;; - use set_ij() for setting pixels of the image
  ;; returns the number of contours found
  (func $find_contours (result i32)
    ;; Topological Structural Analysis of Digitized Binary Images by Border Following.
    ;; Suzuki, S. and Abe, K., CVGIP 30 1, pp 32-46 (1985)

    ;; variables from the paper
    (local $nbd  i32)
    (local $lnbd i32)
    (local $i1   i32)
    (local $j1   i32)
    (local $i1j1 i32) ;; = i1*w+j1
    (local $i2   i32)
    (local $j2   i32)
    (local $i3   i32)
    (local $j3   i32)
    (local $i4   i32)
    (local $j4   i32)
    (local $i4j4 i32) ;; = i4*w+j4
    (local $i    i32)
    (local $j    i32)

    ;; temporary computation results
    (local $now  i32)        ;; value of current pixel
    (local $data_ptr   i32)  ;; pointer at which to write the next vertex
    (local $n_vtx      i32)  ;; number of vertices in current contour
    (local $is_hole    i32)  ;; is current contour a hole
    (local $parent     i32)  ;; parent id of current contour
    (local $b0         i32)  ;; pointer to header of 'lnbd' contour
    (local $b0_is_hole i32)  ;; is 'lnbd' contour a hole
    (local $b0_parent  i32)  ;; parent id of 'lnbd' contour

    (local.set $nbd  (i32.const 1))
    
    (local.set $data_ptr (global.get $offset_contour_data))
    (local.set $n_vtx  (i32.const 0))

    ;; Scan the picture with a TV raster and perform the following steps 
    ;; for each pixel such that fij # 0. Every time we begin to scan a 
    ;; new row of the picture, reset LNBD to 1.
    (local.set $i    (i32.const 0))
    loop $li
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (if (i32.gt_u (local.get $i) (i32.sub (global.get $h) (i32.const 2))) (then
        (i32.sub (local.get $nbd) (i32.const 1))
        return
      ))

      (local.set $lnbd (i32.const 1))
      (local.set $j    (i32.const 0))
      
      loop $lj
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br_if $li (i32.gt_u (local.get $j) (i32.sub (global.get $w) (i32.const 2))))

        (local.set $i2 (i32.const 0))
        (local.set $j2 (i32.const 0))

        (local.set $now (call $get_ij (local.get $i) (local.get $j)))
        
        (br_if $lj (i32.eqz (local.get $now)))

        ;; (a) If fij = 1 and fi, j-1 = 0, then decide that the pixel 
        ;; (i, j) is the border following starting point of an outer 
        ;; border, increment NBD, and (i,, j,) + (i, j - 1).
        (if (i32.and
          (i32.eq (local.get $now) (i32.const 1) )
          (i32.eqz (call $get_ij
            (local.get $i) (i32.sub (local.get $j) (i32.const 1))))
        )(then

          (local.set $nbd (i32.add (local.get $nbd) (i32.const 1)))

          (local.set $i2 (local.get $i))
          (local.set $j2 (i32.sub (local.get $j) (i32.const 1)))

        ;; (b) Else if fij 2 1 and fi,j+l = 0, then decide that the 
        ;; pixel (i, j) is the border following starting point of a 
        ;; hole border, increment NBD, (iz, j,) * (i, j + l), and 
        ;; LNBD + fij in casefij > 1.  
        )(else(if (i32.and
          (i32.gt_s (local.get $now) (i32.const 0) )
          (i32.eqz (call $get_ij
            (local.get $i) (i32.add (local.get $j) (i32.const 1))))
        )(then

          (local.set $nbd (i32.add (local.get $nbd) (i32.const 1)))

          (local.set $i2 (local.get $i))
          (local.set $j2 (i32.add (local.get $j) (i32.const 1)))

          (if (i32.gt_s (local.get $now) (i32.const 1)) (then
            (local.set $lnbd (local.get $now))
          ))

        )(else
          ;; (c) Otherwise, go to (4).
          (if (i32.ne (local.get $now) (i32.const 1)) (then
            (local.set $lnbd (call $abs_i32 (local.get $now)))
          ))
          (br $lj)
        ))))
        ;; (2) Depending on the types of the newly found border 
        ;; and the border with the sequential number LNBD 
        ;; (i.e., the last border met on the current row), 
        ;; decide the parent of the current border as shown in Table 1.
        ;;  TABLE 1
        ;;  Decision Rule for the Parent Border of the Newly Found Border B
        ;;  ----------------------------------------------------------------
        ;;  Type of border B'
        ;;  \    with the sequential
        ;;      \     number LNBD
        ;;  Type of B \                Outer border         Hole border
        ;;  ---------------------------------------------------------------     
        ;;  Outer border               The parent border    The border B'
        ;;                             of the border B'
        ;; 
        ;;  Hole border                The border B'      The parent border
        ;;                                                of the border B'
        ;;  ----------------------------------------------------------------

        (local.set $is_hole (i32.eq (local.get $j2) (i32.add (local.get $j) (i32.const 1))))
        (local.set $parent (i32.const -1))
        (if (i32.gt_s (local.get $lnbd) (i32.const 1)) (then
          (local.set $b0
            (call $get_nth_contour_info (i32.sub (local.get $lnbd) (i32.const 2)))
          )
          (local.set $b0_parent  (i32.load16_u (local.get $b0)))
          (local.set $b0_is_hole (i32.load8_u  (i32.add (local.get $b0) (i32.const 2))))

          (if (local.get $b0_is_hole) (then
            (if (local.get $is_hole) (then
              (local.set $parent (local.get $b0_parent))
            )(else
              (local.set $parent (i32.sub (local.get $lnbd) (i32.const 2)))
            ))
          )(else
            (if (local.get $is_hole) (then
              (local.set $parent (i32.sub (local.get $lnbd) (i32.const 2)))
            )(else
              (local.set $parent (local.get $b0_parent))
            ))
          ))
        ))
        (call $set_nth_contour_info (i32.sub (local.get $nbd) (i32.const 2))
          (local.get $parent)
          (local.get $is_hole)
          (local.get $data_ptr)
          (i32.const 1)
        )

        (call $write_vertex (local.get $data_ptr) (local.get $i) (local.get $j))
        (local.set $data_ptr (i32.add (local.get $data_ptr) (i32.const 4)))
        (local.set $n_vtx (i32.const 1))

        ;; (3) From the starting point (i, j), follow the detected border: 
        ;; this is done by the following substeps (3.1) through (3.5).
        
        ;; (3.1) Starting from (iz, jz), look around clockwise the pixels 
        ;; in the neigh- borhood of (i, j) and tind a nonzero pixel. 
        ;; Let (i,, j,) be the first found nonzero pixel. If no nonzero 
        ;; pixel is found, assign -NBD to fij and go to (4).
        
        (local.set $i1 (i32.const -1))
        (local.set $j1 (i32.const -1))

        (local.set $i1j1 (call $rot_non0 
          (local.get $i) (local.get $j) 
          (local.get $i2) (local.get $j2)
          (i32.const 0) (i32.const -1)
        ))

        (if (i32.eq (local.get $i1j1) (i32.const -1)) (then
          (local.set $now (i32.sub (i32.const 0) (local.get $nbd)))
          (call $set_ij (local.get $i) (local.get $j) (local.get $now))
          
          ;; go to (4)
          (if (i32.ne (local.get $now) (i32.const 1)) (then
            (local.set $lnbd (call $abs_i32 (local.get $now)))
          ))
          (br $lj)
        
        ))
        (local.set $i1 (i32.div_u (local.get $i1j1) (global.get $w)))
        (local.set $j1 (i32.rem_u (local.get $i1j1) (global.get $w)))

        ;; (3.2) &, j,) + (il, j,) ad (is,jd + (4 j).
        (local.set $i2 (local.get $i1))
        (local.set $j2 (local.get $j1))
        (local.set $i3 (local.get $i ))
        (local.set $j3 (local.get $j ))


        loop $while
          (local.set $i4j4 (call $rot_non0
            (local.get $i3) (local.get $j3)
            (local.get $i2) (local.get $j2)
            (i32.const 1) (i32.const 1)
          ))
          (local.set $i4 (i32.div_u (local.get $i4j4) (global.get $w)))
          (local.set $j4 (i32.rem_u (local.get $i4j4) (global.get $w)))


          (call $write_vertex (local.get $data_ptr) (local.get $i4) (local.get $j4))
          (local.set $data_ptr (i32.add (local.get $data_ptr) (i32.const 4)))
          (local.set $n_vtx (i32.add (local.get $n_vtx) (i32.const 1)))
          (call $set_nth_contour_length 
            (i32.sub (local.get $nbd) (i32.const 2)) 
            (local.get $n_vtx)
          )
          ;; (a) If the pixel (i3, j, + 1) is a O-pixel examined in the
          ;; substep (3.3) then fi,, j3 + - NBD.
          (if (i32.eqz
            (call $get_ij (local.get $i3) (i32.add (local.get $j3) (i32.const 1)))
          )(then
            (call $set_ij (local.get $i3) (local.get $j3) 
              (i32.sub (i32.const 0) (local.get $nbd))
            )
          ;; (b) If the pixel (i3, j, + 1) is not a O-pixel examined 
          ;; in the substep (3.3) and fi,,j, = 1, then fi,,j, + NBD.
          )(else(if (i32.eq
            (call $get_ij (local.get $i3) (local.get $j3))
            (i32.const 1)
          )(then
            (call $set_ij (local.get $i3) (local.get $j3) (local.get $nbd))
          ))))
          ;; (c) Otherwise, do not changefi,, jj.

          ;; (3.5) If (i4, j,) = (i, j) and (i3, j,) = (iI, j,) 
          ;; (coming back to the starting point), then go to (4);
          (if (i32.and(i32.and(i32.and
            (i32.eq (local.get $i4) (local.get $i ))
            (i32.eq (local.get $j4) (local.get $j )))
            (i32.eq (local.get $i3) (local.get $i1)))
            (i32.eq (local.get $j3) (local.get $j1)))
          (then
            (if (i32.ne (call $get_ij (local.get $i) (local.get $j)) (i32.const 1)) 
            (then
              (local.set $lnbd (call $abs_i32 (local.get $now)))
            ))
          ;; otherwise, (i2, j,) + (i3, j,),(i,, j,) + (i4, j,), 
          ;; and go back to (3.3).
          )(else
            (local.set $i2 (local.get $i3))
            (local.set $j2 (local.get $j3))
            (local.set $i3 (local.get $i4))
            (local.set $j3 (local.get $j4))
            (br $while)
          ))
        end

        (br_if $lj (i32.lt_u (local.get $j) (i32.sub (global.get $w) (i32.const 2))))
      end

      (br_if $li (i32.lt_u (local.get $i) (i32.sub (global.get $h) (i32.const 2))))
    end

    ;; return
    (i32.sub (local.get $nbd) (i32.const 1))
  )

  ;; user-facing output-reading
  (func $get_nth_contour_parent (param $n i32) (result i32)
    (i32.load16_s (call $get_nth_contour_info (local.get $n)))
  )
  (func $get_nth_contour_is_hole (param $n i32) (result i32)
    (i32.load8_u (i32.add (call $get_nth_contour_info (local.get $n)) (i32.const 2)))
  )
  (func $get_nth_contour_offset (param $n i32) (result i32)
    (i32.load    (i32.add (call $get_nth_contour_info (local.get $n)) (i32.const 4)))
  )
  (func $get_nth_contour_length (param $n i32) (result i32)
    (i32.load    (i32.add (call $get_nth_contour_info (local.get $n)) (i32.const 8)))
  )
  (func $get_nth_vertex (param $offset i32) (param $n i32) (result i32)
    (i32.load (i32.add
      (local.get $offset) 
      (i32.mul (local.get $n) (i32.const 4))
    ))
  )

  ;; exported API's
  (export "get_ij"                  (func $get_ij                 ))
  (export "set_ij"                  (func $set_ij                 ))
  (export "setup"                   (func $setup                  ))
  (export "find_contours"           (func $find_contours          ))
  (export "get_nth_contour_parent"  (func $get_nth_contour_parent ))
  (export "get_nth_contour_is_hole" (func $get_nth_contour_is_hole))
  (export "get_nth_contour_offset"  (func $get_nth_contour_offset ))
  (export "get_nth_contour_length"  (func $get_nth_contour_length ))
  (export "get_nth_vertex"          (func $get_nth_vertex         ))
  (export "mem"                     (memory $mem                  ))

)

