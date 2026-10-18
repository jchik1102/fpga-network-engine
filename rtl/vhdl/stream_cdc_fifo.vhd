-- VHDL-2008 version of rtl/stream_cdc_fifo.sv: an asynchronous FIFO for a
-- ready/valid stream crossing between two unrelated clocks (Gray-code
-- pointers, after Cummings, "Simulation and Synthesis Techniques for
-- Asynchronous FIFO Design").
--
-- Same ports, generics, registers and register names as the SystemVerilog
-- module, so the two can be checked against each other by name
-- (scripts/vhdl-cdc-fifo.sh runs the cocotb tests on this file with GHDL and
-- an equivalence check against the SystemVerilog with EQY).
--
-- Each side keeps a binary pointer one bit wider than the address and a Gray
-- copy of it. Only the Gray pointers cross domains, each through a two-flop
-- synchronizer; because a Gray pointer changes one bit per increment, the
-- receiving side samples either the old or the new value, never a mix. The
-- write side compares its pointer with the synchronized read pointer (full);
-- the read side compares with the synchronized write pointer (empty). Both
-- views lag the other side, so full and empty can only be pessimistic: the
-- FIFO never overflows or underflows. The read port is first-word-fall-through.
--
-- Resets are synchronous to their own clocks and must be asserted together
-- (a system reset), so both sides start empty. ADDR must be at least 2.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity stream_cdc_fifo is
  generic (
    WIDTH : positive := 37;   -- {last, keep[3:0], data[31:0]} for the 32-bit packet stream
    ADDR  : positive := 4     -- 2**ADDR entries
  );
  port (
    s_clk, s_rst : in  std_logic;
    s_data       : in  std_logic_vector(WIDTH-1 downto 0);
    s_valid      : in  std_logic;
    s_ready      : out std_logic;
    m_clk, m_rst : in  std_logic;
    m_data       : out std_logic_vector(WIDTH-1 downto 0);
    m_valid      : out std_logic;
    m_ready      : in  std_logic
  );
end entity stream_cdc_fifo;

architecture rtl of stream_cdc_fifo is
  constant DEPTH : positive := 2**ADDR;
  subtype ptr_t is unsigned(ADDR downto 0);
  type mem_t is array (0 to DEPTH-1) of std_logic_vector(WIDTH-1 downto 0);

  signal mem : mem_t;
  signal w_bin, w_gray, r_bin, r_gray : ptr_t;
  -- Synchronizer stages: the other side's Gray pointer, two flops deep. The
  -- attributes mark them for Quartus's metastability analysis and, with
  -- ASYNC_REG, keep Vivado from separating or optimizing the two flops.
  signal w_sync1, w_sync2, r_sync1, r_sync2 : ptr_t;
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of w_sync1, w_sync2, r_sync1, r_sync2 : signal is "TRUE";
  attribute altera_attribute : string;
  attribute altera_attribute of w_sync1, w_sync2, r_sync1, r_sync2 : signal is
    "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS";

  signal w_bin_next, r_bin_next : ptr_t;
  signal full, empty, s_ready_i, m_valid_i, write_en : std_logic;

  function to_gray(b : ptr_t) return ptr_t is
  begin
    return b xor shift_right(b, 1);
  end function;
begin
  -- ------------------------------------------------------------ write side
  w_bin_next <= w_bin + 1;
  -- Full when the write pointer is a whole lap ahead of the synchronized read
  -- pointer: in Gray code, the top two bits differ and the rest are equal.
  full <= '1' when w_gray = ((not r_sync2(ADDR downto ADDR-1)) & r_sync2(ADDR-2 downto 0)) else '0';
  s_ready_i <= not s_rst and not full;
  s_ready <= s_ready_i;
  write_en <= s_valid and s_ready_i;

  write_side : process (s_clk)
  begin
    if rising_edge(s_clk) then
      if s_rst = '1' then
        w_bin <= (others => '0'); w_gray <= (others => '0');
        r_sync1 <= (others => '0'); r_sync2 <= (others => '0');
      else
        r_sync1 <= r_gray; r_sync2 <= r_sync1;
        if write_en = '1' then
          w_bin <= w_bin_next;
          w_gray <= to_gray(w_bin_next);
        end if;
      end if;
    end if;
  end process;

  -- The storage has no reset, in its own process so synthesis sees a plain
  -- RAM write port. write_en is already low in reset (through s_ready_i);
  -- the s_rst term repeats the SystemVerilog, where the write sits in the
  -- reset's else branch, so the equivalence check can match the two even
  -- when it treats s_ready as a free cut point.
  storage : process (s_clk)
  begin
    if rising_edge(s_clk) then
      if s_rst = '0' and write_en = '1' then
        mem(to_integer(w_bin(ADDR-1 downto 0))) <= s_data;
      end if;
    end if;
  end process;

  -- ------------------------------------------------------------- read side
  r_bin_next <= r_bin + 1;
  empty <= '1' when r_gray = w_sync2 else '0';
  m_valid_i <= not m_rst and not empty;
  m_valid <= m_valid_i;
  m_data <= mem(to_integer(r_bin(ADDR-1 downto 0)));

  read_side : process (m_clk)
  begin
    if rising_edge(m_clk) then
      if m_rst = '1' then
        r_bin <= (others => '0'); r_gray <= (others => '0');
        w_sync1 <= (others => '0'); w_sync2 <= (others => '0');
      else
        w_sync1 <= w_gray; w_sync2 <= w_sync1;
        if m_valid_i = '1' and m_ready = '1' then
          r_bin <= r_bin_next;
          r_gray <= to_gray(r_bin_next);
        end if;
      end if;
    end if;
  end process;
end architecture rtl;
