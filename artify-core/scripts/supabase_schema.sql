-- Create Authors Table
CREATE TABLE IF NOT EXISTS public.authors (
    id uuid PRIMARY KEY NOT NULL,
    name character varying(255) NOT NULL,
    born character varying(255) NOT NULL,
    died character varying(255) NOT NULL,
    nationality character varying(255) NOT NULL,
    wikipedia character varying(255) NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    original_source character varying(255) DEFAULT ''::character varying NOT NULL
);

-- Create Photos Table
CREATE TABLE IF NOT EXISTS public.photos (
    id uuid PRIMARY KEY NOT NULL,
    name character varying(255) NOT NULL,
    image_url character varying(255) NOT NULL,
    author_id uuid NOT NULL REFERENCES public.authors(id) ON DELETE RESTRICT,
    width integer NOT NULL,
    height integer NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    info text NOT NULL,
    date character varying(255) NOT NULL,
    style character varying(255) NOT NULL,
    location character varying(255) NOT NULL,
    dimensions character varying(255) NOT NULL,
    media character varying(255) NOT NULL,
    original_source character varying(255) DEFAULT ''::character varying NOT NULL,
    is_favorite boolean DEFAULT false NOT NULL
);

-- Create Dashboards Table
CREATE TABLE IF NOT EXISTS public.dashboards (
    id uuid PRIMARY KEY NOT NULL,
    type character varying(255) NOT NULL,
    photo_id uuid NOT NULL REFERENCES public.photos(id) ON DELETE RESTRICT,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);

-- Create Versions Table
CREATE TABLE IF NOT EXISTS public.versions (
    id uuid PRIMARY KEY NOT NULL,
    build_version character varying(255) NOT NULL,
    build_number integer NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    url character varying(255) NOT NULL,
    notes text NOT NULL
);

-- Index for fast retrieval
CREATE INDEX IF NOT EXISTS photos_created_at_idx ON public.photos USING btree (created_at);
