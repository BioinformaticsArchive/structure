require 'structure/alignment'

module Structure

  def self.sequence_position_in_pdb(protein_sequence, protein_positions, pdb, pdbfile)
    chains = PDBHelper.pdb_chain_sequences(pdb, pdbfile)

    protein_positions = [protein_positions] unless Array === protein_positions
    alignments = {}
    chains.each do |chain,chain_sequence|

      chain_alignment, protein_alignment = SmithWaterman.align(chain_sequence, protein_sequence)

      alignments[chain] = Structure.match_position(protein_positions, protein_alignment, chain_alignment)
    end

    #alignments.delete_if{|c,p| p.nil? or p.empty?}

    TSV.setup(alignments, :key_field => "PDB Chain", :fields => protein_positions, :type => :list, :cast => :to_i)
  end


  def self.pdb_chain_position_in_sequence(pdb, pdbfile, chain, positions, protein_sequence)
    protein_alignment, chain_alignment = 
      Persist.persist("SW PDB Alignment", :marshal,
                      :dir => Rbbt.var.cache.persist.find(:lib),
                      :other => {:pdb => pdb, :pdbfile => pdbfile, :chain => chain, :protein_sequence => protein_sequence}) {

      chains = PDBHelper.pdb_chain_sequences(pdb, pdbfile)
      chain_sequence = chains[chain] 
      SmithWaterman.align(protein_sequence, chain_sequence)
    }

    seq_pos = Structure.match_position(positions, chain_alignment, protein_alignment)
    res = Hash[*positions.zip(seq_pos).flatten]
    TSV.setup(res, :key_field => "Chain position", :fields => ["Sequence position"], :type => :single)
  end


  def self.pdb_alignment_map(protein_sequence, pdb, pdbfile)
    chains = PDBHelper.pdb_chain_sequences(pdb, pdbfile)

    result = TSV.setup({}, :key_field => "Sequence position", :fields => ["Chain:Position in PDB"], :type => :flat)
    chains.each do |chain,chain_sequence|
      chain_alignment, protein_alignment = SmithWaterman.align(chain_sequence, protein_sequence)

      map = Structure.alignment_map(protein_alignment, chain_alignment)

      map.each do |seq_pos, chain_pos|
        if result[seq_pos].nil?
          result[seq_pos] = [[chain, chain_pos] * ":"]
        else
          result[seq_pos] << [chain, chain_pos] * ":"
        end
      end
    end

    result
  end

  def self.pdb_positions_to_sequence(pdb_positions, sequence, target_chain, pdb = nil, pdbfile = nil)
    chain_positions = {}
    pdb_positions.collect do |cp|
      chain, position = cp.split(":")
      chain_positions[chain] ||= []
      chain_positions[chain] << position
    end
    return [] unless chain_positions.include? target_chain
    Structure.job(:pdb_chain_position_in_sequence, "TEST", :pdb => pdb, :pdbfile => pdbfile, :sequence => sequence, :chain => target_chain, :positions => chain_positions[target_chain]).exec
  end

  def self.neighbours_in_pdb(sequence, positions, pdb = nil, pdbfile = nil, chain = nil, distance = 5)

    positions_in_pdb = Structure.job(:sequence_position_in_pdb, "TEST", :pdb => pdb, :pdbfile => pdbfile, :sequence => sequence, :positions => positions).exec

    Log.debug "Position in PDB: #{Misc.fingerprint positions_in_pdb}"

    chain ||=  positions_in_pdb.sort{|c,p| p.nil? ? 0 : p.length}.last.first

    neighbours_in_pdb = TSV.setup({}, :key_field => "Sequence position", :fields => ["Neighbours"], :type => :flat)

    return neighbours_in_pdb if positions_in_pdb.nil? or positions_in_pdb[chain].nil?

    neighbour_map = Structure.job(:neighbour_map, "PDB Neighbours", :pdb => pdb, :pdbfile => pdbfile, :distance => distance).run

    return neighbours_in_pdb if neighbour_map.nil?

    inverse_neighbour_map = {}
    neighbour_map.each do |k,vs|
      vs.each do |v|
        inverse_neighbour_map[v] ||= []
        inverse_neighbour_map[v] << k
      end
    end

    positions_in_pdb[chain].each do |position|
      position_in_chain = [chain, position] * ":"
      neigh = neighbour_map[position_in_chain]
      ineigh = inverse_neighbour_map[position_in_chain]
      all_neighbours = (neigh || []) + (ineigh || []).uniq

      position_in_sequence = Structure.pdb_chain_position_in_sequence(pdb, pdbfile, chain, [position], sequence).values.compact.flatten.first
      all_neighbours_in_sequence = all_neighbours.collect{|n| c,p = n.split(":"); Structure.pdb_chain_position_in_sequence(pdb, pdbfile, c, [p], sequence).values.compact.flatten }.flatten.uniq
      neighbours_in_pdb[position_in_sequence] = all_neighbours_in_sequence
    end

    neighbours_in_pdb
  end

  def self.neighbour_map(distance, pdb = nil, pdbfile = nil)
    close_residues = PDBHelper.pdb_close_residues(distance, pdb, pdbfile)
    TSV.setup close_residues, :key_field => "Residue", :fields => ["Neighbours"], :type => :flat
  end

end

