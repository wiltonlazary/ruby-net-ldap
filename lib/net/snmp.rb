# $Id$
#
# NET::SNMP
#
#----------------------------------------------------------------------------
#
# Copyright (C) 2006-07 by Francis Cianfrocca. All Rights Reserved.
#
# Gmail: garbagecat10
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
#
#---------------------------------------------------------------------------
#
#

require 'net/ber'


module Net

    class SNMP

	AsnSyntax = BER.compile_syntax({
	    :application => {
		:primitive => {
		    1 => :integer,	# Counter32, (RFC1155 sec 6)
		    2 => :integer,	# Gauge32, (RFC1155 sec 6)
		    3 => :integer	# TimeTicks32, (RFC1155 sec 6)
		},
		:constructed => {
		}
	    },
	    :context_specific => {
		:primitive => {
		},
		:constructed => {
		    0 => :array,	# GetRequest PDU (RFC1157 pgh 4.1.2)
		    1 => :array,	# GetNextRequest PDU (RFC1157 pgh 4.1.3)
		    2 => :array		# GetResponse PDU (RFC1157 pgh 4.1.4)
		}
	    }
	})

	# SNMP 32-bit counter.
	# Defined in RFC1155 (Structure of Mangement Information), section 6.
	# A 32-bit counter is an ASN.1 application [1] implicit unsigned integer
	# with a range from 0 to 2^^32 - 1.
	class Counter32
	    def initialize value
		@value = value
	    end
	    def to_ber
		@value.to_ber_application(1)
	    end
	end

	# SNMP 32-bit gauge.
	# Defined in RFC1155 (Structure of Mangement Information), section 6.
	# A 32-bit counter is an ASN.1 application [2] implicit unsigned integer.
	class Gauge32
	    def initialize value
		@value = value
	    end
	    def to_ber
		@value.to_ber_application(2)
	    end
	end

	# SNMP 32-bit timer-ticks.
	# Defined in RFC1155 (Structure of Mangement Information), section 6.
	# A 32-bit counter is an ASN.1 application [3] implicit unsigned integer.
	class TimerTicks32
	    def initialize value
		@value = value
	    end
	    def to_ber
		@value.to_ber_application(3)
	    end
	end
    end

    class SnmpPdu
	class Error < Exception; end

	PduTypes = [
	    :get_request,
	    :get_next_request,
	    :get_response,
	    :set_request,
	    :trap
	]
	ErrorStatusCodes = { # Per RFC1157, pgh 4.1.1
	    0 => "noError",
	    1 => "tooBig",
	    2 => "noSuchName",
	    3 => "badValue",
	    4 => "readOnly",
	    5 => "genErr"
	}

	class << self
	    def parse ber_object
		n = new
		n.send :parse, ber_object
		n
	    end
	end

	attr_reader :version, :community, :pdu_type, :variables, :error_status
	attr_accessor :request_id, :error_index


	def initialize args={}
	    @version = args[:version] || 0
	    @community = args[:community] || "public"
	    @pdu_type = args[:pdu_type] # leave nil unless specified; there's no reasonable default value.
	    @error_status = args[:error_status] || 0
	    @error_index = args[:error_index] || 0
	    @variables = args[:variables] || []
	end

	#--
	def parse ber_object
	    begin
		parse_ber_object ber_object
	    rescue Error
		# Pass through any SnmpPdu::Error instances
		raise $!
	    rescue
		# Wrap any basic parsing error so it becomes a PDU-format error
		raise Error.new( "snmp-pdu format error" )
	    end
	end
	private :parse

	def parse_ber_object ber_object
	    version= ber_object[0].to_i

	    community= ber_object[1].to_s

	    data = ber_object[2]
	    case (app_tag = data.ber_identifier & 31)
	    when 0
		send :pdu_type=, :get_request
		parse_get_request data
	    when 1
		send :pdu_type=, :get_next_request
		# This PDU is identical to get-request except for the type.
		parse_get_request data
	    when 2
		send :pdu_type=, :get_response
		# This PDU is identical to get-request except for the type,
		# and the fact that the variable bindings will be non-null.
		parse_get_request data
	    else
		raise Error.new( "unknown snmp-pdu type: #{app_tag}" )
	    end
	end
	private :parse_ber_object

	#--
	# Defined in RFC1157, pgh 4.1.2.
	def parse_get_request data
	    send :request_id=, data[0].to_i
	    # data[1] is error-status, always 0.
	    # data[2] is error-index, always 0.
	    data[3].each {|n,v|
		# A variable-binding, of which there may be several,
		# consists of an OID and a BER null.
		# We're ignoring the null, we might want to verify it instead.
		unless v.is_a?(Net::BER::BerIdentifiedNull)
		    raise Error.new(" invalid variable-binding in get-request" )
		end
		add_variable_binding n, nil
	    }
	end
	private :parse_get_request


	def version= ver
	    unless [0,2].include?(ver)
		raise Error.new("unknown snmp-version: #{ver}")
	    end
	    @version = ver
	end

	def pdu_type= t
	    unless PduTypes.include?(t)
		raise Error.new("unknown pdu-type: #{t}")
	    end
	    @pdu_type = t
	end

	def error_status= es
	    unless ErrorStatusCodes.has_key?(es)
		raise Error.new("unknown error-status: #{es}")
	    end
	    @error_status = es
	end

	def community= c
	    @community = c.to_s
	end

	#--
	# Syntactic sugar
	def add_variable_binding name, value=nil
	    @variables ||= []
	    @variables << [name, value]
	end

	def to_ber_string
	    [
		version.to_ber,
		community.to_ber,
		pdu_to_ber_string
	    ].to_ber_sequence
	end

	#--
	# Helper method that returns a PDU payload in BER form,
	# depending on the PDU type.
	def pdu_to_ber_string
	    case pdu_type
	    when :get_request
		[
		    request_id.to_ber,
		    error_status.to_ber,
		    error_index.to_ber,
		    [
			@variables.map {|n,v|
			    [n.to_ber_oid, Net::BER::BerIdentifiedNull.new.to_ber].to_ber_sequence
			}
		    ].to_ber_sequence
		].to_ber_contextspecific(0)
	    when :get_next_request
		[
		    request_id.to_ber,
		    error_status.to_ber,
		    error_index.to_ber,
		    [
			@variables.map {|n,v|
			    [n.to_ber_oid, Net::BER::BerIdentifiedNull.new.to_ber].to_ber_sequence
			}
		    ].to_ber_sequence
		].to_ber_contextspecific(1)
	    when :get_response
		[
		    request_id.to_ber,
		    error_status.to_ber,
		    error_index.to_ber,
		    [
			@variables.map {|n,v|
			    [n.to_ber_oid, v.to_ber].to_ber_sequence
			}
		    ].to_ber_sequence
		].to_ber_contextspecific(2)
	    else
		raise Error.new( "unknown pdu-type: #{pdu_type}" )
	    end
	end
	private :pdu_to_ber_string

    end
end

