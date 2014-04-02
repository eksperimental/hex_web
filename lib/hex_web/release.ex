defmodule HexWeb.Release do
  use Ecto.Model

  import Ecto.Query, only: [from: 2]
  import HexWeb.Validation
  alias HexWeb.Util

  queryable "releases" do
    belongs_to :package, HexWeb.Package
    field :version, :string
    has_many :requirements, HexWeb.Requirement
    field :created_at, :datetime
    field :updated_at, :datetime
  end

  validatep validate(release),
    version: present() and type(:string) and valid_version(pre: false)

  validatep validate_create(release),
    also: validate(),
    also: unique([:version], scope: [:package_id], on: HexWeb.Repo)

  def create(package, version, requirements, created_at \\ nil) do
    now = Util.ecto_now
    release = package.releases.new(version: version, updated_at: now,
                                   created_at: created_at || now)

    case validate_create(release) do
      [] ->
        HexWeb.Repo.transaction(fn ->
          release = HexWeb.Repo.create(release)
          update_requirements(release.package(package), requirements)
        end)
      errors ->
        { :error, errors }
    end
  end

  def update(release, requirements) do
    if editable?(release) do
      case validate(release) do
        [] ->
          HexWeb.Repo.transaction(fn ->
            HexWeb.Repo.delete_all(release.requirements)
            HexWeb.Repo.delete(release)
            create(release.package.get, release.version, requirements, release.created_at)
          end) |> elem(1)
        errors ->
          { :error, errors }
      end

    else
      { :error, [created_at: "can only modify a release up to one hour after creation"] }
    end
  end

  def delete(release) do
    if editable?(release) do
      HexWeb.Repo.transaction(fn ->
        HexWeb.Repo.delete_all(release.requirements)
        HexWeb.Repo.delete(release)
      end)

      :ok
    else
      { :error, [created_at: "can only delete a release up to one hour after creation"] }
    end
  end

  # TODO: Prereleases should always be editable
  defp editable?(release) do
    created_at = Ecto.DateTime.to_erl(release.created_at) |> :calendar.datetime_to_gregorian_seconds
    now        = :calendar.universal_time |> :calendar.datetime_to_gregorian_seconds

    now - created_at <= 3600
  end

  defp update_requirements(release, requirements) do
    results = create_requirements(release, requirements)

    errors = Enum.filter_map(results, &match?({ :error, _ }, &1), &elem(&1, 1))
    if errors == [] do
      release.requirements(requirements)
    else
      HexWeb.Repo.rollback(deps: errors)
    end
  end

  defp create_requirements(release, requirements) do
    requirements = Enum.map(requirements, fn { k, v } -> { to_string(k), v } end)
    deps = Dict.keys(requirements)

    deps_query =
         from p in HexWeb.Package,
       where: p.name in array(^deps, ^:string),
      select: { p.name, p.id }
    deps = HexWeb.Repo.all(deps_query) |> HashDict.new

    Enum.map(requirements, fn { dep, req } ->
      cond do
        not valid_requirement?(req) ->
          { :error, { dep, "invalid requirement: #{inspect req}" } }

        id = deps[dep] ->
          release.requirements.new(requirement: req, dependency_id: id)
          |> HexWeb.Repo.create()
          { dep, req }

        true ->
          { :error, { dep, "unknown package" } }
      end
    end)
  end

  def all(package) do
    HexWeb.Repo.all(package.releases)
    |> Enum.map(&(&1.package(package)))
    |> Enum.sort(&(Version.compare(&1.version, &2.version) == :gt))
  end

  def get(package, version) do
    release =
      from(r in package.releases, where: r.version == ^version, limit: 1)
      |> HexWeb.Repo.all
      |> List.first

    if release do
      reqs = requirements(release)
      release.package(package)
             .requirements(reqs)
    end
  end

  def requirements(release) do
    from(req in release.requirements,
             join: p in req.dependency,
             select: { p.name, req.requirement })
    |> HexWeb.Repo.all
  end

  def count do
    HexWeb.Repo.all(from(r in HexWeb.Release, select: count(r.id)))
    |> List.first
  end

  defp valid_requirement?(req) do
    nil?(req) or (is_binary(req) and match?({ :ok, _ }, Version.parse_requirement(req)))
  end
end

defimpl HexWeb.Render, for: HexWeb.Release.Entity do
  import HexWeb.Util

  def render(release) do
    package = release.package.get
    reqs    = release.requirements.to_list

    release.__entity__(:keywords)
    |> Dict.take([:version, :created_at, :updated_at])
    |> Dict.update!(:created_at, &to_iso8601/1)
    |> Dict.update!(:updated_at, &to_iso8601/1)
    |> Dict.put(:url, api_url(["packages", package.name, "releases", release.version]))
    |> Dict.put(:package_url, api_url(["packages", package.name]))
    |> Dict.put(:requirements, reqs)
  end
end