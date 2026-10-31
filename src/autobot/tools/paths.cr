module Autobot::Tools
  def self.resolve_roots(roots : Array(String), workspace : Path?) : Array(Path)
    base = workspace || Path[Dir.current]
    roots.map { |root| Path[root].expand(base: base, home: true) }
  end

  def self.inside?(path : Path, root : Path) : Bool
    path == root || path.to_s.starts_with?("#{root.to_s.chomp("/")}/")
  end

  # Resolves symlinks for the existing part of a path and keeps the rest,
  # so a path about to be created is confined like an existing one.
  def self.realpath(path : Path) : Path
    rest = [] of String
    current = path
    until File.exists?(current.to_s)
      if File.symlink?(current.to_s)
        target = Path[File.readlink(current.to_s)].expand(base: current.parent)
        return realpath(target).join(rest)
      end
      parent = current.parent
      return current.join(rest) if parent == current
      rest.unshift(current.basename)
      current = parent
    end
    Path[File.realpath(current.to_s)].join(rest)
  end
end
