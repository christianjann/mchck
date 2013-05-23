require 'log'
require 'adiv5'
require 'register'

class ARMv7
end

require 'armv7-scs'
require 'armv7-fpb'

class ARMv7
  def initialize(adiv5)
    @dap = adiv5.dap
    @scs = SCS.new(@dap)
  end

  def probe!
    @dap.devs.each do |d|
      puts "%s at %08x" % [d, d.base]
      # case d.base
      #   # when 0xe0001000
      #   #   @dwt = DWT.new(@dap)
      #   # when 0xe0002000
      #   #   @fpb = FPB.new(@dap)
      #   # when 0xe0000000
      #   #   @itm = ITM.new(@dap)
      #   # when 0xe0040000
      #   #   @tpiu = TPIU.new(@dap)
      #   # when 0xe0041000
      #   #   @etm = ETM.new(@dap)
      # end
    end
  end

  def enable_debug!
    Log(:arm, 1){ "enabling debug" }
    @scs.DHCSR.transact do |dhcsr|
      dhcsr.zero!
      dhcsr.DBGKEY = :key
      dhcsr.C_DEBUGEN = true
    end
  end

  def disable_debug!
    Log(:arm, 1){ "disabling debug" }
    @scs.DHCSR.transact do |dhcsr|
      dhcsr.DBGKEY = :key
      dhcsr.C_HALT = false
      dhcsr.C_DEBUGEN = false
    end
  end

  def catch_vector!(name, do_catch=true)
    # if name is true, catch all
    if name == true
      name = SCS::DEMCR.instance_methods.map{|m| m.match(/^VC_(.*?)=$/) && $1}.compact
    end
    Log(:arm, 1){ "catching vector #{name}" }
    name = [name] if not Array === name
    @scs.DEMCR.transact do |demcr|
      name.each do |n|
        vcname = "VC_#{n}"
        demcr.send("#{vcname}=", do_catch)
      end
    end
  end

  def halt_core!
    Log(:arm, 1){ "waiting for core to halt" }
    while !self.core_halted?
      @scs.DHCSR.transact do |dhcsr|
        dhcsr.DBGKEY = :key
        dhcsr.C_DEBUGEN = true
        dhcsr.C_HALT = true
      end
    end
  end

  def continue!
    Log(:arm, 1){ "releasing core" }
    @scs.DHCSR.transact do |dhcsr|
      dhcsr.DBGKEY = :key
      dhcsr.C_MASKINTS = false
      dhcsr.C_STEP = false
      dhcsr.C_HALT = false
    end
  end

  def single_step!
    Log(:arm, 1){ "single stepping core" }
    @scs.DHCSR.transact do |dhcsr|
      dhcsr.DBGKEY = :key
      dhcsr.C_MASKINTS = true
      dhcsr.C_STEP = true
      dhcsr.C_HALT = false
    end
  end

  def core_halted?
    @scs.DHCSR.S_HALT
  end

  def halt_reason
    reason = @scs.DFSR.dup
    # reset sticky bits
    @scs.DFSR.replace!(reason.to_i)

    if reason.EXTERNAL
      :EXTERN
    elsif reason.VCATCH
      :SEGV
    elsif reason.BKPT
      :TRAP
    else
      if @scs.DHCSR.C_STEP
        :TRAP
      else
        :INT
      end
    end
  end

  def reset_system!
    Log(:arm, 1){ "resetting system" }
    @scs.AIRCR.transact do |aircr|
      aircr.VECTKEY = :key
      aircr.SYSRESETREQ = true
    end
  end

  def get_register(reg, as_bytes=false)
    @scs.DCRSR.transact do |dcrsr|
      dcrsr.zero!
      dcrsr.REGWnR = :read
      dcrsr.REGSEL = reg
    end
    while !@scs.DHCSR.S_REGRDY
      sleep 0.01
    end
    val = @scs.DCRDR
    Log(:arm, 3){ "get register %s < %08x" % [reg, val] }
    val = [val].pack('L') if as_bytes
    val
  end

  def set_register!(reg, val)
    val = val.unpack('L').first if String === val
    @scs.DCRDR = val
    @scs.DCRSR.transact do |dcrsr|
      dcrsr.zero!
      dcrsr.REGWnR = :write
      dcrsr.REGSEL = reg
    end
    while !@scs.DHCSR.S_REGRDY
      sleep 0.01
    end
    Log(:arm, 3){ "set register %s = %08x" % [reg, val] }
    val
  end

  def read_registers
    res = ""
    self.reg_desc.each do |rd|
      res << get_register(rd[:name], true)
    end
    res
  end

  def write_registers!(regdata)
    self.reg_desc.zip(regdata.unpack('L*')) do |rd, val|
      set_register!(rd[:name], val)
    end
  end

  def read_mem(addr, count)
    # we need to deal with unaligned addresses
    res = ""
    remaining = count
    align_start = addr % 4
    if align_start > 0
      data = @dap.read(addr - align_start)
      res << [data].pack('L')[align_start..-1]
      read_size = 4 - align_start
      addr += read_size
      remaining -= read_size
    end
    numwords = (remaining + 3) / 4
    if numwords >= 1
      data = @dap.read(addr, :count => numwords)
      res << data.pack('L*')
    end
    res[0...count]
  end

  def write_mem(addr, data)
    dary = []
    align_start = addr % 4
    if align_start > 0
      word = @dap.read(addr - align_start)
      wordbytes = [word].pack('L')
      write_size = 4 - align_start
      databytes = data.slice!(0, write_size)
      wordbytes[align_start, databytes.bytesize] = databytes
      dary += wordbytes.unpack('L')
      addr -= align_start
    end
    dary += data.unpack('L*')
    align_end = data.bytesize % 4
    if align_end > 0
      word = @dap.read(addr + dary.size * 4)
      wordbytes = [word].pack('L')
      wordbytes[0...align_end] = data[(-align_end)..-1]
      dary += wordbytes.unpack('L')
    end
    @dap.write(addr, dary)
    nil
  end

  def reg_desc
    regs = (0..12).map{|i| {:name => "r#{i}".to_sym}}
    regs << {:name => :sp, :type => "data_ptr"}
    regs << {:name => :lr, :type => "code_ptr"}
    regs << {:name => :pc, :type => "code_ptr"}
    regs << {:name => :xpsr}
    regs << {:name => :msp, :type => "data_ptr", "save-restore" => "no"}
    regs << {:name => :psp, :type => "data_ptr", "save-restore" => "no"}
    regs << {:name => :flags, "save-restore" => "no"}
    regs
  end

  def tdesc
    features = tdesc_features.join("\n")
    s =  <<__end__
<?xml version="1.0"?>
<!DOCTYPE target SYSTEM "gdb-target.dtd">
<target version="1.0">
  <architecture>arm</architecture>
  #{features}
</target>
__end__
    s
  end

  def tdesc_feature_m_profile
    regstr = self.reg_desc.map do |h|
      hs = h.map{|k,v| '%s="%s"' % [k,v]}.join(' ')
      "<reg #{hs} bitsize=\"32\"/>"
    end.join("\n")
    "<feature name=\"org.gnu.gdb.arm.m-profile\">#{regstr}</feature>"
  end

  def tdesc_features
    [self.tdesc_feature_m_profile]
  end
end

if $0 == __FILE__
  adiv5 = Adiv5.new(FtdiSwd, :vid => Integer(ARGV[0]), :pid => Integer(ARGV[1]), :debug => true)
  armv7 = ARMv7.new(adiv5)
  armv7.enable_debug!
  armv7.catch_vector!(:CORERESET)
  armv7.halt_core!
end