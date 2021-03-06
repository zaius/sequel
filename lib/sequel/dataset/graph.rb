module Sequel
  class Dataset
    # ---------------------
    # :section: Methods related to dataset graphing
    # Dataset graphing changes the dataset to yield hashes where keys are table
    # name symbols and columns are hashes representing the values related to
    # that table.  All of these methods return modified copies of the receiver.
    # ---------------------
    
    # Adds the given graph aliases to the list of graph aliases to use,
    # unlike #set_graph_aliases, which replaces the list.  See
    # #set_graph_aliases.
    def add_graph_aliases(graph_aliases)
      ds = select_more(*graph_alias_columns(graph_aliases))
      ds.opts[:graph_aliases] = (ds.opts[:graph_aliases] || (ds.opts[:graph][:column_aliases] rescue {}) || {}).merge(graph_aliases)
      ds
    end

    # Allows you to join multiple datasets/tables and have the result set
    # split into component tables.
    #
    # This differs from the usual usage of join, which returns the result set
    # as a single hash.  For example:
    #
    #   # CREATE TABLE artists (id INTEGER, name TEXT);
    #   # CREATE TABLE albums (id INTEGER, name TEXT, artist_id INTEGER);
    #   DB[:artists].left_outer_join(:albums, :artist_id=>:id).first
    #   => {:id=>albums.id, :name=>albums.name, :artist_id=>albums.artist_id}
    #   DB[:artists].graph(:albums, :artist_id=>:id).first
    #   => {:artists=>{:id=>artists.id, :name=>artists.name}, :albums=>{:id=>albums.id, :name=>albums.name, :artist_id=>albums.artist_id}}
    #
    # Using a join such as left_outer_join, the attribute names that are shared between
    # the tables are combined in the single return hash.  You can get around that by
    # using .select with correct aliases for all of the columns, but it is simpler to
    # use graph and have the result set split for you.  In addition, graph respects
    # any row_proc of the current dataset and the datasets you use with graph.
    #
    # If you are graphing a table and all columns for that table are nil, this
    # indicates that no matching rows existed in the table, so graph will return nil
    # instead of a hash with all nil values:
    #
    #   # If the artist doesn't have any albums
    #   DB[:artists].graph(:albums, :artist_id=>:id).first
    #   => {:artists=>{:id=>artists.id, :name=>artists.name}, :albums=>nil}
    #
    # Arguments:
    # * dataset -  Can be a symbol (specifying a table), another dataset,
    #   or an object that responds to .dataset and return a symbol or a dataset
    # * join_conditions - Any condition(s) allowed by join_table.
    # * options -  A hash of graph options.  The following options are currently used:
    #   * :from_self_alias - The alias to use when the receiver is not a graphed
    #     dataset but it contains multiple FROM tables or a JOIN.  In this case,
    #     the receiver is wrapped in a from_self before graphing, and this option
    #     determines the alias to use.
    #   * :implicit_qualifier - The qualifier of implicit conditions, see #join_table.
    #   * :join_type - The type of join to use (passed to join_table).  Defaults to
    #     :left_outer.
    #   * :select - An array of columns to select.  When not used, selects
    #     all columns in the given dataset.  When set to false, selects no
    #     columns and is like simply joining the tables, though graph keeps
    #     some metadata about join that makes it important to use graph instead
    #     of join.
    #   * :table_alias - The alias to use for the table.  If not specified, doesn't
    #     alias the table.  You will get an error if the the alias (or table) name is
    #     used more than once.
    # * block - A block that is passed to join_table.
    def graph(dataset, join_conditions = nil, options = {}, &block)
      # Allow the use of a model, dataset, or symbol as the first argument
      # Find the table name/dataset based on the argument
      dataset = dataset.dataset if dataset.respond_to?(:dataset)
      table_alias = options[:table_alias]
      case dataset
      when Symbol
        table = dataset
        dataset = @db[dataset]
        table_alias ||= table
      when ::Sequel::Dataset
        if dataset.simple_select_all?
          table = dataset.opts[:from].first
          table_alias ||= table
        else
          table = dataset
          table_alias ||= dataset_alias((@opts[:num_dataset_sources] || 0)+1)
        end
      else
        raise Error, "The dataset argument should be a symbol, dataset, or model"
      end

      # Raise Sequel::Error with explanation that the table alias has been used
      raise_alias_error = lambda do
        raise(Error, "this #{options[:table_alias] ? 'alias' : 'table'} has already been been used, please specify " \
          "#{options[:table_alias] ? 'a different alias' : 'an alias via the :table_alias option'}") 
      end

      # Only allow table aliases that haven't been used
      raise_alias_error.call if @opts[:graph] && @opts[:graph][:table_aliases] && @opts[:graph][:table_aliases].include?(table_alias)
      
      # Use a from_self if this is already a joined table
      ds = (!@opts[:graph] && (@opts[:from].length > 1 || @opts[:join])) ? from_self(:alias=>options[:from_self_alias] || first_source) : self
      
      # Join the table early in order to avoid cloning the dataset twice
      ds = ds.join_table(options[:join_type] || :left_outer, table, join_conditions, :table_alias=>table_alias, :implicit_qualifier=>options[:implicit_qualifier], &block)
      opts = ds.opts

      # Whether to include the table in the result set
      add_table = options[:select] == false ? false : true
      # Whether to add the columns to the list of column aliases
      add_columns = !ds.opts.include?(:graph_aliases)

      # Setup the initial graph data structure if it doesn't exist
      unless graph = opts[:graph]
        master = alias_symbol(ds.first_source_alias)
        raise_alias_error.call if master == table_alias
        # Master hash storing all .graph related information
        graph = opts[:graph] = {}
        # Associates column aliases back to tables and columns
        column_aliases = graph[:column_aliases] = {}
        # Associates table alias (the master is never aliased)
        table_aliases = graph[:table_aliases] = {master=>self}
        # Keep track of the alias numbers used
        ca_num = graph[:column_alias_num] = Hash.new(0)
        # All columns in the master table are never
        # aliased, but are not included if set_graph_aliases
        # has been used.
        if add_columns
          select = opts[:select] = []
          columns.each do |column|
            column_aliases[column] = [master, column]
            select.push(SQL::QualifiedIdentifier.new(master, column))
          end
        end
      end

      # Add the table alias to the list of aliases
      # Even if it isn't been used in the result set,
      # we add a key for it with a nil value so we can check if it
      # is used more than once
      table_aliases = graph[:table_aliases]
      table_aliases[table_alias] = add_table ? dataset : nil

      # Add the columns to the selection unless we are ignoring them
      if add_table && add_columns
        select = opts[:select]
        column_aliases = graph[:column_aliases]
        ca_num = graph[:column_alias_num]
        # Which columns to add to the result set
        cols = options[:select] || dataset.columns
        # If the column hasn't been used yet, don't alias it.
        # If it has been used, try table_column.
        # If that has been used, try table_column_N 
        # using the next value of N that we know hasn't been
        # used
        cols.each do |column|
          col_alias, identifier = if column_aliases[column]
            column_alias = :"#{table_alias}_#{column}"
            if column_aliases[column_alias]
              column_alias_num = ca_num[column_alias]
              column_alias = :"#{column_alias}_#{column_alias_num}" 
              ca_num[column_alias] += 1
            end
            [column_alias, SQL::QualifiedIdentifier.new(table_alias, column).as(column_alias)]
          else
            [column, SQL::QualifiedIdentifier.new(table_alias, column)]
          end
          column_aliases[col_alias] = [table_alias, column]
          select.push(identifier)
        end
      end
      ds
    end

    # This allows you to manually specify the graph aliases to use
    # when using graph.  You can use it to only select certain
    # columns, and have those columns mapped to specific aliases
    # in the result set.  This is the equivalent of .select for a
    # graphed dataset, and must be used instead of .select whenever
    # graphing is used. Example:
    #
    #   DB[:artists].graph(:albums, :artist_id=>:id).set_graph_aliases(:artist_name=>[:artists, :name], :album_name=>[:albums, :name], :forty_two=>[:albums, :fourtwo, 42]).first
    #   => {:artists=>{:name=>artists.name}, :albums=>{:name=>albums.name, :fourtwo=>42}}
    #
    # Arguments:
    # * graph_aliases - Should be a hash with keys being symbols of
    #   column aliases, and values being arrays with two or three elements.
    #   The first element of the array should be the table alias symbol,
    #   and the second should be the actual column name symbol. If the array
    #   has a third element, it is used as the value returned, instead of
    #   table_alias.column_name.
    def set_graph_aliases(graph_aliases)
      ds = select(*graph_alias_columns(graph_aliases))
      ds.opts[:graph_aliases] = graph_aliases
      ds
    end

    # Remove the splitting of results into subhashes.  Also removes
    # metadata related to graphing, so you should not call graph
    # any tables to this dataset after calling this method.
    def ungraphed
      clone(:graph=>nil)
    end

    private

    # Transform the hash of graph aliases to an array of columns
    def graph_alias_columns(graph_aliases)
      graph_aliases.collect do |col_alias, tc| 
        identifier = tc[2] || SQL::QualifiedIdentifier.new(tc[0], tc[1])
        identifier = SQL::AliasedExpression.new(identifier, col_alias) if tc[2] or tc[1] != col_alias
        identifier
      end
    end

    # Fetch the rows, split them into component table parts,
    # tranform and run the row_proc on each part (if applicable),
    # and yield a hash of the parts.
    def graph_each
      # Reject tables with nil datasets, as they are excluded from
      # the result set
      datasets = @opts[:graph][:table_aliases].to_a.reject{|ta,ds| ds.nil?}
      # Get just the list of table aliases into a local variable, for speed
      table_aliases = datasets.collect{|ta,ds| ta}
      # Get an array of arrays, one for each dataset, with
      # the necessary information about each dataset, for speed
      datasets = datasets.collect{|ta, ds| [ta, ds, ds.row_proc]}
      # Use the manually set graph aliases, if any, otherwise
      # use the ones automatically created by .graph
      column_aliases = @opts[:graph_aliases] || @opts[:graph][:column_aliases]
      fetch_rows(select_sql) do |r|
        graph = {}
        # Create the sub hashes, one per table
        table_aliases.each{|ta| graph[ta]={}}
        # Split the result set based on the column aliases
        # If there are columns in the result set that are
        # not in column_aliases, they are ignored
        column_aliases.each do |col_alias, tc|
          ta, column = tc
          graph[ta][column] = r[col_alias]
        end
        # For each dataset run the row_proc if applicable
        datasets.each do |ta,ds,rp|
          g = graph[ta]
          graph[ta] = if g.values.any?{|x| !x.nil?}
            rp ? rp.call(g) : g
          else
            nil
          end
        end

        yield graph
      end
      self
    end
  end
end
