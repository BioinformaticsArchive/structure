module Structure
 
  input :residues, :tsv, "Proteins and their affected residues", nil
  input :organism, :string, "Organism code", "Hsa"
  task :annotate_residues_InterPro => :tsv do |residues, organism|
    raise ParameterException, "No residues provided" if residues.nil?
    tsv = TSV.setup({}, :key_field => "Ensembl Protein ID", :fields => ["Residue", "InterPro ID", "Range"], :type => :double)

    iso2uni = Organism.protein_identifiers(organism).index :target => "UniProt/SwissProt Accession", :persist => true
    iso2sequence = Organism.protein_sequence(organism).tsv :type => :single, :persist => true

    residues.monitor = {:desc => "Annotated residues InterPro"}
    TSV.traverse residues, :cpus => $cpus, :into => tsv do |isoform, list|
      list = Array === list ? list.flatten : [list]

      uniprot = iso2uni[isoform]
      next if uniprot.nil?
      sequence = iso2sequence[isoform]
      next if sequence.nil?

      features = Structure.corrected_interpro_features(uniprot, sequence)
      overlapping = [[],[],[]]
      list.each do |position|
        position = position.to_i
        features.select{|info|
          info[:start] <= position and info[:end] >= position
        }.each{|info|
          overlapping[0] << position
          overlapping[1] << info[:code]
          overlapping[2] << [info[:start], info[:end]] * ":"
        }
      end

      [isoform, overlapping]
    end

    missing = residues.size - tsv.size
    if missing > 0
      Log.warn "Some isoforms failed to translate to UniProt: #{missing}"
      set_info(:missing, missing)
    end

    tsv
  end
  export_asynchronous :annotate_residues_InterPro

  input :residues, :tsv, "Proteins and their affected residues", nil
  input :organism, :string, "Organism code", "Hsa"
  task :annotate_residues_UniProt => :tsv do |residues, organism|
    raise ParameterException, "No residues provided" if residues.nil?
    tsv = TSV.setup({}, :key_field => "Ensembl Protein ID", :fields => ["Residue", "UniProt Features", "UniProt Feature locations", "UniProt Feature Descriptions"], :type => :double)

    iso2uni = Organism.protein_identifiers(organism).index :target => "UniProt/SwissProt Accession", :persist => true
    iso2sequence = Organism.protein_sequence(organism).tsv :type => :single, :persist => true

    residues.monitor = {:desc => "Annotated residues UniProt"}
    TSV.traverse residues, :cpus => $cpus, :into => tsv do |isoform, list|
      list = Array === list ? list.flatten : [list]

      uniprot = iso2uni[isoform]
      if uniprot.nil?
        next
      end

      features = Structure.corrected_uniprot_features(uniprot, iso2sequence[isoform])
      overlapping = [[],[],[],[]]
      list.each do |position|
        position = position.to_i
        features.select{|info|
          case info[:type]
          when "VAR_SEQ", "CONFLICT", "CHAIN", "UNSURE"
            false
          when "DISULFID", "CROSSLNK", "VARIANT"
            info[:start] == position or info[:end] == position
          else
            info[:start] <= position and info[:end] >= position
          end
        }.each{|info|
          overlapping[0] << position
          overlapping[1] << info[:type]
          overlapping[2] << [info[:start], info[:end]] * ":"
          overlapping[3] << (info[:description] || "").strip.sub(/\.$/,'')
        }
      end

      [isoform, overlapping]
    end

    missing = residues.size - tsv.size
    if missing > 0
      Log.warn "Some isoforms failed to translate to UniProt: #{missing}"
      set_info(:missing, missing)
    end

    tsv
  end
  export_asynchronous :annotate_residues_UniProt

  dep :annotate_residues_UniProt
  task :annotate_residues_UniProt_variants => :tsv do |residues, organism|
    residue_annotations = step(:annotate_residues_UniProt).join.path.open
    annotations = Structure.UniProt_mutation_annotations
    tsv = TSV.setup({}, :key_field => "Ensembl Protein ID", :fields => ["Residue", "UniProt Variant ID", "Change", "Type of Variant", "SNP ID", "Disease"], :type => :double)
    TSV.traverse residue_annotations, :into => tsv do |isoform, values|
      entries = []
      Misc.zip_fields(values).select{|residue,feature,location,description|
        feature == "VARIANT"
      }.each{|residue,feature,location,description|
        if description.match(/(VAR_\d+)/)
          id = $1
          next unless annotations.include? id
          entries << [residue, id].concat(annotations[id])
        end
      }
      [isoform.first, Misc.zip_fields(entries)]
    end
    tsv
  end
  export_asynchronous :annotate_residues_UniProt_variants

  input :residues, :tsv, "Proteins and their affected residues", nil
  task :annotate_residues_Appris => :tsv do |residues|
    tsv = TSV.setup({}, :key_field => "Ensembl Protein ID", :fields => ["Residue", "Appris Features", "Appris Feature locations", "Appris Feature Descriptions"], :type => :double)

    residues.monitor = {:desc => "Annotated residues Appris"}
    TSV.traverse residues, :cpus => $cpus, :into => tsv do |isoform, list|
      list = Array === list ? list.flatten : [list]

      features = Structure.appris_features(isoform)

      overlapping = [[],[],[],[]]
      list.each do |position|
        position = position.to_i
        features.select{|info|
          info[:start] <= position and info[:end] >= position
        }.each{|info|
          overlapping[0] << position
          overlapping[1] << info[:type]
          overlapping[2] << [info[:start], info[:end]] * ":"
          overlapping[3] << (info[:description] || "").strip.sub(/\.$/,'')
        }
      end

    #  tsv[isoform] = overlapping
      [isoform, overlapping]
    end

    tsv
  end
  export_asynchronous :annotate_residues_Appris

  input :residues, :tsv, "Proteins and their affected residues", nil
  task :annotate_residues_COSMIC => :tsv do |residues|

    cosmic_residue_mutations = Structure.COSMIC_residues

    isoform_matched_variants = {}
    residues.monitor = {:desc => "Annotated residues COSMIC"}
    TSV.traverse residues, :cpus => $cpus, :into => isoform_matched_variants do |isoform, list|
      list = Array === list ? list.flatten : [list]

      all_matching_mutations = []
      list.each do |position|
        matching_mutations = cosmic_residue_mutations[[isoform, position]*":"]
        next if matching_mutations.nil? or matching_mutations.empty?
        all_matching_mutations.concat matching_mutations
      end
      [isoform, all_matching_mutations]
    end

    cosmic_mutation_annotations = Structure.COSMIC_mutation_annotations

    res = TSV.setup({}, :key_field => "Ensembl Protein ID", :fields => ["Residue", "Genomic Mutation"].concat(cosmic_mutation_annotations.fields), :type => :double)

    residues.monitor = {:desc => "Annotated residues COSMIC"}
    TSV.traverse isoform_matched_variants, :cpus => $cpus, :into => res do |isoform, mutations|
      values = []
      mutations.each do |mutation|
        begin
          annotations = cosmic_mutation_annotations[mutation]
          raise "No annotations for #{ mutation } in #{cosmic_mutation_annotations.persistence_path}" if annotations.nil?
          aa_mutation = (annotations.first || []).compact.first
          raise "No AA mutation" if aa_mutation.nil?
          if aa_mutation.match(/(\d+)/)
            residue = $1
          else
            raise "AA mutation does not have a position: #{ aa_mutation }" if aa_mutation.nil?
          end
          values << [residue,mutation].concat(annotations || [])
        rescue
          Log.exception $!
          next
        end
      end

      [isoform, Misc.zip_fields(values)]
    end

    res
  end
  export_asynchronous :annotate_residues_COSMIC

  input :residues, :tsv, "Proteins and their affected residues", nil
  input :organism, :string, "Organism code", "Hsa"
  task :residue_interfaces => :tsv do |residues, organism|

    neighbour_residues = {}

    residues.with_monitor :desc => "Processing residues" do
    TSV.traverse residues, :cpus => $cpus, :into => neighbour_residues do |protein, list|
      list = list.flatten.compact.sort
      begin
        neighbours = Structure.interface_neighbours_i3d(protein.dup, list, organism)
        next if neighbours.nil? or neighbours.empty?
        neighbours
      rescue
        Log.exception $!
        next
      end
    end
    end

    TSV.setup(neighbour_residues, :key_field => "Isoform", :fields => ["Position", "Partner Ensembl Protein ID", "PDB", "Partner residues"], :type => :double)
  end
  export_asynchronous :residue_interfaces

end
