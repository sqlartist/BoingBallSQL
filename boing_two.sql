/*==============================================================================
  BOING II — two balls, with collision, inside SQL Server.

  The one-statement trick from the single-ball version does not survive contact
  physics. Previously each ball's position was a closed-form function of the
  frame number, so `frames` could join in as just another dimension of the
  cross product. Collision response depends on the state of the previous step,
  so that is gone.

  Rather than fight it, the two halves are split along the line where they
  actually differ:

    SIMULATION  is genuinely sequential. It is also tiny -- two rows, a few
                hundred substeps. A WHILE loop driving set-based UPDATEs.
                Written pairwise, so it takes N balls, not just two.

    RENDERING   is still one INSERT ... SELECT. It no longer computes where the
                balls are, it joins to where the simulator says they were.

  A note on why this is not a recursive CTE, which would have been prettier:
  the recursive member may reference the CTE only once, and pairwise collision
  needs a self-join. You can dodge that by carrying both balls in a single wide
  row, but then it is hard-coded to two balls and every intermediate term has
  to be re-expanded inline because subqueries and APPLY are not allowed in the
  recursive member either. The loop is worse SQL and a much better artefact.

  Requires SQL Server 2017+. Standalone: run top to bottom.

    0  schema                    5  the render
    1  numbers table             6  ASCII smoke test
    2  configuration             7  BMP emitter
    3  palette and ball setup
    4  the simulator
==============================================================================*/

SET NOCOUNT ON;
GO

/*------------------------------------------------------------------ 0. schema */
IF SCHEMA_ID('boing') IS NULL EXEC ('CREATE SCHEMA boing');
GO

/*----------------------------------------------------------- 1. numbers table */
DROP TABLE IF EXISTS boing.num;
GO
CREATE TABLE boing.num (n int NOT NULL PRIMARY KEY CLUSTERED);
GO
INSERT boing.num (n)
SELECT TOP (65536) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
FROM   sys.all_columns a CROSS JOIN sys.all_columns b;
GO

/*----------------------------------------------------------- 2. configuration */
DROP TABLE IF EXISTS boing.config;
GO
CREATE TABLE boing.config
(
    id         tinyint NOT NULL CONSTRAINT pk_config PRIMARY KEY
                       CONSTRAINT ck_config_single CHECK (id = 1),
    scr_w      int     NOT NULL,   -- multiple of 4 so BMP rows need no padding
    scr_h      int     NOT NULL,
    n_frames   int     NOT NULL,
    substeps   int     NOT NULL,   -- physics steps per rendered frame
    dt         float   NOT NULL,
    gravity    float   NOT NULL,   -- px per substep squared
    radius     float   NOT NULL,
    tilt_deg   float   NOT NULL,
    spin       float   NOT NULL,   -- radians of spin per radius of travel
    n_lon      int     NOT NULL,
    n_lat      int     NOT NULL,
    sh_dx      float   NOT NULL,
    sh_dy      float   NOT NULL,
    grid_size  float   NOT NULL,
    grid_width float   NOT NULL
);
GO
INSERT boing.config
      (id, scr_w, scr_h, n_frames, substeps, dt, gravity, radius,
       tilt_deg, spin, n_lon, n_lat, sh_dx, sh_dy, grid_size, grid_width)
VALUES ( 1,   320,   256,      120,        8,  1,   0.055,     40,
             -17, 1.10,    12,     6,    26,    18,        16,          2);
GO

/*--------------------------------------------------- 3. palette and ball setup */
DROP TABLE IF EXISTS boing.palette;
GO
CREATE TABLE boing.palette
(
    idx  tinyint     NOT NULL CONSTRAINT pk_palette PRIMARY KEY,
    name varchar(30) NOT NULL,
    r    tinyint     NOT NULL,
    g    tinyint     NOT NULL,
    b    tinyint     NOT NULL
);
GO
INSERT boing.palette (idx, name, r, g, b) VALUES
    (0, 'background',        170, 170, 170),
    (1, 'grid line',         136,  34, 153),
    (2, 'background shadow', 119, 119, 119),
    (3, 'grid line shadow',   92,  23, 104),
    (4, 'ball 1 red',        226,  27,  27),
    (5, 'ball 1 white',      242, 242, 242),
    (6, 'ball 2 blue',        30,  80, 220),
    (7, 'ball 2 white',      242, 242, 242);
GO

/* Initial conditions. Add rows here and everything downstream copes: the
   simulator is pairwise and the renderer resolves depth by nearest surface. */
DROP TABLE IF EXISTS boing.ball_def;
GO
CREATE TABLE boing.ball_def
(
    ball  tinyint NOT NULL CONSTRAINT pk_ball_def PRIMARY KEY,
    cx0   float   NOT NULL,
    cy0   float   NOT NULL,
    vx0   float   NOT NULL,
    vy0   float   NOT NULL,
    pal_a tinyint NOT NULL,      -- palette index for even checks
    pal_b tinyint NOT NULL       -- palette index for odd checks
);
GO
INSERT boing.ball_def (ball, cx0, cy0, vx0, vy0, pal_a, pal_b) VALUES
    (0,  80,  70,  2.05, 0, 4, 5),
    (1, 240, 130, -1.55, 0, 6, 7);
GO

/* Live simulation state, and the per-frame record the renderer reads. */
DROP TABLE IF EXISTS boing.ball;
GO
CREATE TABLE boing.ball
(
    ball tinyint NOT NULL CONSTRAINT pk_ball PRIMARY KEY,
    cx   float   NOT NULL,
    cy   float   NOT NULL,
    vx   float   NOT NULL,
    vy   float   NOT NULL,
    ang  float   NOT NULL
);
GO

DROP TABLE IF EXISTS boing.ball_state;
GO
CREATE TABLE boing.ball_state
(
    frame smallint NOT NULL,
    ball  tinyint  NOT NULL,
    cx    float    NOT NULL,
    cy    float    NOT NULL,
    ang   float    NOT NULL,
    CONSTRAINT pk_ball_state PRIMARY KEY CLUSTERED (frame, ball)
);
GO

/*==============================================================================
  4. THE SIMULATOR

  Semi-implicit Euler, perfectly elastic everywhere. Restitution is 1 on
  purpose: with any energy loss the balls settle and the animation dies, and
  with e = 1 under gravity the total energy is conserved so it runs forever.

  Each substep is four set-based statements. Note that T-SQL UPDATE has
  all-at-once semantics -- every SET expression sees the pre-update row -- which
  is what makes the wall reflection safe to write as one statement rather than
  needing a temporary.
==============================================================================*/
CREATE OR ALTER PROCEDURE boing.simulate
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @w float, @h float, @r float, @g float, @dt float, @spin float,
            @nf int, @ss int, @f int = 0, @s int;

    SELECT @w = scr_w, @h = scr_h, @r = radius, @g = gravity, @dt = dt,
           @spin = spin, @nf = n_frames, @ss = substeps
    FROM   boing.config;

    DELETE boing.ball;
    INSERT boing.ball (ball, cx, cy, vx, vy, ang)
    SELECT ball, cx0, cy0, vx0, vy0, 0e0 FROM boing.ball_def;

    TRUNCATE TABLE boing.ball_state;

    WHILE @f < @nf
    BEGIN
        SET @s = 0;

        WHILE @s < @ss
        BEGIN
            /* (a) gravity, spin, integrate. cy uses the post-gravity vy. */
            UPDATE boing.ball
            SET vy  = vy + @g * @dt,
                ang = ang + @spin * vx * @dt / @r,
                cx  = cx + vx * @dt,
                cy  = cy + (vy + @g * @dt) * @dt;

            /* (b) walls: clamp and reflect, only if actually moving outward */
            UPDATE boing.ball
            SET cx = CASE WHEN cx < @r      AND vx < 0 THEN @r
                          WHEN cx > @w - @r AND vx > 0 THEN @w - @r
                          ELSE cx END,
                vx = CASE WHEN (cx < @r      AND vx < 0)
                            OR (cx > @w - @r AND vx > 0) THEN -vx ELSE vx END,
                cy = CASE WHEN cy < @r      AND vy < 0 THEN @r
                          WHEN cy > @h - @r AND vy > 0 THEN @h - @r
                          ELSE cy END,
                vy = CASE WHEN (cy < @r      AND vy < 0)
                            OR (cy > @h - @r AND vy > 0) THEN -vy ELSE vy END;

            /* (c) pairwise contact. Separation whenever overlapping; normal
                   velocity exchange only when the pair is closing. Equal
                   masses, so the exchange is just +/- vn along the normal.
                   Deltas are summed per ball, so simultaneous contacts add. */
            ;WITH pair AS
            (
                SELECT  ia  = a.ball, ib = b.ball,
                        avx = a.vx,   avy = a.vy,
                        bvx = b.vx,   bvy = b.vy,
                        d.dist,
                        nx  = (b.cx - a.cx) / d.dist,
                        ny  = (b.cy - a.cy) / d.dist
                FROM        boing.ball a
                INNER JOIN  boing.ball b ON b.ball > a.ball
                CROSS APPLY (SELECT dist = SQRT(SQUARE(b.cx - a.cx)
                                              + SQUARE(b.cy - a.cy))) d
                WHERE   d.dist < 2e0 * @r
                  AND   d.dist > 0e0
            ),
            resolved AS
            (
                SELECT *, ov = 2e0 * @r - dist,
                          vn = (bvx - avx) * nx + (bvy - avy) * ny
                FROM   pair
            ),
            delta AS
            (
                SELECT  ball = ia,
                        dcx = -ov / 2e0 * nx,  dcy = -ov / 2e0 * ny,
                        dvx = CASE WHEN vn < 0 THEN  vn * nx ELSE 0e0 END,
                        dvy = CASE WHEN vn < 0 THEN  vn * ny ELSE 0e0 END
                FROM    resolved
                UNION ALL
                SELECT  ball = ib,
                        dcx =  ov / 2e0 * nx,  dcy =  ov / 2e0 * ny,
                        dvx = CASE WHEN vn < 0 THEN -vn * nx ELSE 0e0 END,
                        dvy = CASE WHEN vn < 0 THEN -vn * ny ELSE 0e0 END
                FROM    resolved
            ),
            agg AS
            (
                SELECT ball, dcx = SUM(dcx), dcy = SUM(dcy),
                             dvx = SUM(dvx), dvy = SUM(dvy)
                FROM   delta GROUP BY ball
            )
            UPDATE b
            SET    cx = b.cx + agg.dcx, cy = b.cy + agg.dcy,
                   vx = b.vx + agg.dvx, vy = b.vy + agg.dvy
            FROM   boing.ball b
            INNER JOIN agg ON agg.ball = b.ball;

            SET @s += 1;
        END

        INSERT boing.ball_state (frame, ball, cx, cy, ang)
        SELECT @f, ball, cx, cy, ang FROM boing.ball;

        SET @f += 1;
    END
END
GO

DECLARE @t0 datetime2(3) = SYSUTCDATETIME();
EXEC boing.simulate;
SELECT sim_rows = (SELECT COUNT(*) FROM boing.ball_state),
       sim_ms   = DATEDIFF(millisecond, @t0, SYSUTCDATETIME());
GO

/*==============================================================================
  5. THE RENDER

  Still one statement, but now three passes composed as CTEs rather than a
  single shader chain, because depth has to be resolved before a pixel can be
  coloured:

    ball_px    for each ball, only the pixels inside its bounding box. Both
               spheres sit at the same z with the same radius, so the nearer
               surface at any shared pixel is simply the smaller d2 --
               ROW_NUMBER over (frame, y, x) ordered by d2 picks the winner.
    shadow_px  the same bounding-box trick on the offset silhouettes.
    compose    the full pixel grid, left joined to both.

  Visiting only bounding boxes rather than testing every pixel against every
  ball is what keeps this cheap: about 1.5M candidate rows instead of 9.8M
  correlated lookups.

  SQRT is still guarded with ABS rather than a CASE -- SQL Server does not
  promise to short-circuit CASE, so a guard that looks safe can still raise an
  invalid floating point operation depending on the plan.
==============================================================================*/
DROP TABLE IF EXISTS boing.frame_px;
GO
CREATE TABLE boing.frame_px
(
    frame smallint NOT NULL,
    y     smallint NOT NULL,
    x     smallint NOT NULL,
    idx   tinyint  NOT NULL,
    CONSTRAINT pk_frame_px PRIMARY KEY CLUSTERED (frame, y, x)
);
GO

DECLARE @t0 datetime2(3) = SYSUTCDATETIME();

WITH ball_px AS
(
    SELECT  z.frame, z.y, z.x, z.idx,
            rn = ROW_NUMBER() OVER (PARTITION BY z.frame, z.y, z.x
                                    ORDER BY z.d2)
    FROM
    (
        SELECT      b.frame, py.y, px_.x, dd.d2,
                    idx = CASE WHEN k.par = 0 THEN bd.pal_a ELSE bd.pal_b END
        FROM        boing.config c
        CROSS JOIN  boing.ball_state b
        INNER JOIN  boing.ball_def bd ON bd.ball = b.ball
        /* bounding box only */
        CROSS APPLY (SELECT y = n FROM boing.num
                     WHERE n >= b.cy - c.radius AND n <= b.cy + c.radius
                       AND n >= 0 AND n < c.scr_h)                          py
        CROSS APPLY (SELECT x = n FROM boing.num
                     WHERE n >= b.cx - c.radius AND n <= b.cx + c.radius
                       AND n >= 0 AND n < c.scr_w)                          px_
        CROSS APPLY (SELECT fx = px_.x + 0.5e0, fy = py.y + 0.5e0)          pc
        CROSS APPLY (SELECT dx = pc.fx - b.cx, dy = pc.fy - b.cy)           d
        CROSS APPLY (SELECT d2 = SQUARE(d.dx) + SQUARE(d.dy))               dd
        /* surface normal under orthographic projection */
        CROSS APPLY (SELECT nx = d.dx / c.radius,
                            ny = d.dy / c.radius,
                            nz = -SQRT(ABS(1.0e0 - dd.d2 / SQUARE(c.radius)))) n
        /* undo the axis tilt, then undo this ball's own spin */
        CROSS APPLY (SELECT ct = COS(-RADIANS(c.tilt_deg)),
                            st = SIN(-RADIANS(c.tilt_deg)),
                            ca = COS(-b.ang), sa = SIN(-b.ang))             rot
        CROSS APPLY (SELECT tx = n.nx * rot.ct - n.ny * rot.st,
                            ty = n.nx * rot.st + n.ny * rot.ct,
                            tz = n.nz)                                      tl
        CROSS APPLY (SELECT wx =  tl.tx * rot.ca + tl.tz * rot.sa,
                            wy =  tl.ty,
                            wz = -tl.tx * rot.sa + tl.tz * rot.ca)          w
        CROSS APPLY (SELECT lon = ATN2(w.wx, w.wz) / (2.0e0 * PI()) + 0.5e0,
                            lat = ACOS(CASE WHEN w.wy >  1.0e0 THEN  1.0e0
                                            WHEN w.wy < -1.0e0 THEN -1.0e0
                                            ELSE w.wy END) / PI())          uv
        CROSS APPLY (SELECT par = (CAST(FLOOR(uv.lon * c.n_lon) AS int)
                                 + CAST(FLOOR(uv.lat * c.n_lat) AS int)
                                 + 1024) % 2)                               k
        WHERE       dd.d2 <= SQUARE(c.radius)
    ) z
),
shadow_px AS
(
    SELECT      DISTINCT b.frame, py.y, px_.x
    FROM        boing.config c
    CROSS JOIN  boing.ball_state b
    CROSS APPLY (SELECT sy = b.cy + c.sh_dy, sx = b.cx + c.sh_dx)           sc
    CROSS APPLY (SELECT y = n FROM boing.num
                 WHERE n >= sc.sy - c.radius AND n <= sc.sy + c.radius
                   AND n >= 0 AND n < c.scr_h)                              py
    CROSS APPLY (SELECT x = n FROM boing.num
                 WHERE n >= sc.sx - c.radius AND n <= sc.sx + c.radius
                   AND n >= 0 AND n < c.scr_w)                              px_
    WHERE       SQUARE(px_.x + 0.5e0 - sc.sx)
              + SQUARE(py.y  + 0.5e0 - sc.sy) <= SQUARE(c.radius)
)
INSERT boing.frame_px WITH (TABLOCK) (frame, y, x, idx)
SELECT      f.n, py.y, px_.x,
            COALESCE(bp.idx,
                     CASE WHEN sp.x IS NOT NULL
                          THEN CASE WHEN g.bg = 1 THEN 3 ELSE 2 END
                          ELSE CASE WHEN g.bg = 1 THEN 1 ELSE 0 END END)
FROM        boing.config c
CROSS APPLY (SELECT n FROM boing.num WHERE n < c.n_frames)                  f
CROSS APPLY (SELECT y = n FROM boing.num WHERE n < c.scr_h)                 py
CROSS APPLY (SELECT x = n FROM boing.num WHERE n < c.scr_w)                 px_
CROSS APPLY (SELECT fx = px_.x + 0.5e0, fy = py.y + 0.5e0)                  pc
CROSS APPLY (SELECT bg = CASE
                WHEN pc.fx - FLOOR(pc.fx / c.grid_size) * c.grid_size < c.grid_width
                  OR pc.fy - FLOOR(pc.fy / c.grid_size) * c.grid_size < c.grid_width
                THEN 1 ELSE 0 END)                                          g
LEFT JOIN   ball_px   bp ON bp.frame = f.n AND bp.y = py.y AND bp.x = px_.x
                        AND bp.rn = 1
LEFT JOIN   shadow_px sp ON sp.frame = f.n AND sp.y = py.y AND sp.x = px_.x;

SELECT rendered_rows = @@ROWCOUNT,
       render_ms     = DATEDIFF(millisecond, @t0, SYSUTCDATETIME());
GO

/*==============================================================================
  6. ASCII smoke test
     '.' background  '+' grid  ':' shadow  '%' grid in shadow
     '#' ball 1 red  'o' ball 1 white  '@' ball 2 blue  '*' ball 2 white
==============================================================================*/
CREATE OR ALTER PROCEDURE boing.render_ascii
    @frame smallint = 0,
    @step  int      = 4
AS
BEGIN
    SET NOCOUNT ON;

    SELECT  line = STRING_AGG(CASE p.idx WHEN 0 THEN '.'
                                         WHEN 1 THEN '+'
                                         WHEN 2 THEN ':'
                                         WHEN 3 THEN '%'
                                         WHEN 4 THEN '#'
                                         WHEN 5 THEN 'o'
                                         WHEN 6 THEN '@'
                                         ELSE        '*' END, '')
                   WITHIN GROUP (ORDER BY p.x)
    FROM    boing.frame_px p
    WHERE   p.frame = @frame
      AND   p.x % @step       = 0
      AND   p.y % (@step * 2) = 0
    GROUP BY p.y
    ORDER BY p.y;
END
GO

-- EXEC boing.render_ascii @frame = 6;   -- first contact with the defaults

/* Which frames actually collide, for picking something worth looking at. */
CREATE OR ALTER VIEW boing.contact
AS
SELECT  a.frame,
        separation = SQRT(SQUARE(b.cx - a.cx) + SQUARE(b.cy - a.cy))
FROM    boing.ball_state a
INNER JOIN boing.ball_state b ON b.frame = a.frame AND b.ball > a.ball;
GO

-- SELECT TOP (10) * FROM boing.contact ORDER BY separation;

/*==============================================================================
  7. BMP emitter — unchanged from the single-ball version
==============================================================================*/
CREATE OR ALTER FUNCTION boing.le4 (@v int) RETURNS binary(4)
AS
BEGIN
    RETURN CAST(CAST( @v             % 256 AS tinyint) AS binary(1))
         + CAST(CAST((@v / 256)      % 256 AS tinyint) AS binary(1))
         + CAST(CAST((@v / 65536)    % 256 AS tinyint) AS binary(1))
         + CAST(CAST((@v / 16777216) % 256 AS tinyint) AS binary(1));
END
GO

CREATE OR ALTER FUNCTION boing.le2 (@v int) RETURNS binary(2)
AS
BEGIN
    RETURN CAST(CAST( @v        % 256 AS tinyint) AS binary(1))
         + CAST(CAST((@v / 256) % 256 AS tinyint) AS binary(1));
END
GO

CREATE OR ALTER PROCEDURE boing.get_bmp
    @frame smallint,
    @bmp   varbinary(max) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @w int, @h int;
    SELECT @w = scr_w, @h = scr_h FROM boing.config;

    IF @w % 4 <> 0
        THROW 50001, 'Width must be a multiple of 4 or BMP rows need padding.', 1;

    DECLARE @pal varchar(max);
    SELECT  @pal = STRING_AGG(CONVERT(varchar(max), z.h), '') WITHIN GROUP (ORDER BY z.n)
    FROM   (SELECT n.n,
                   h = CONVERT(char(2), CONVERT(binary(1), ISNULL(p.b, 0)), 2)
                     + CONVERT(char(2), CONVERT(binary(1), ISNULL(p.g, 0)), 2)
                     + CONVERT(char(2), CONVERT(binary(1), ISNULL(p.r, 0)), 2)
                     + '00'
            FROM   boing.num n
            LEFT   JOIN boing.palette p ON p.idx = n.n
            WHERE  n.n < 256) z;

    DECLARE @px varchar(max);
    ;WITH scanline AS
    (
        SELECT  y,
                hexrow = STRING_AGG(CONVERT(char(2), CONVERT(binary(1), idx), 2), '')
                         WITHIN GROUP (ORDER BY x)
        FROM    boing.frame_px
        WHERE   frame = @frame
        GROUP BY y
    )
    SELECT @px = STRING_AGG(CONVERT(varchar(max), hexrow), '') WITHIN GROUP (ORDER BY y DESC)
    FROM   scanline;

    IF @px IS NULL THROW 50002, 'No such frame in boing.frame_px.', 1;

    DECLARE @offset int = 14 + 40 + 1024;
    DECLARE @imgsz  int = @w * @h;

    SET @bmp =
          0x424D
        + boing.le4(@offset + @imgsz)
        + 0x00000000
        + boing.le4(@offset)
        + boing.le4(40)
        + boing.le4(@w)
        + boing.le4(@h)
        + boing.le2(1)
        + boing.le2(8)
        + boing.le4(0)
        + boing.le4(@imgsz)
        + boing.le4(2835) + boing.le4(2835)
        + boing.le4(256)
        + boing.le4(0)
        + CONVERT(varbinary(max), @pal, 2)
        + CONVERT(varbinary(max), @px,  2);
END
GO

CREATE OR ALTER PROCEDURE boing.get_all_bmp
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @out TABLE (frame smallint PRIMARY KEY, bmp varbinary(max));
    DECLARE @f smallint = 0, @n smallint, @b varbinary(max);
    SELECT @n = n_frames FROM boing.config;

    WHILE @f < @n
    BEGIN
        EXEC boing.get_bmp @frame = @f, @bmp = @b OUTPUT;
        INSERT @out (frame, bmp) VALUES (@f, @b);
        SET @f += 1;
    END

    SELECT frame, bmp FROM @out ORDER BY frame;
END
GO
